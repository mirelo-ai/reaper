-- Async HTTP for ReaScript, with zero blocking of REAPER's UI thread.
--
-- Strategy (this is the whole "networking wall" the Electron build worried about):
--   1. Write every curl option into a `-K` config file (URL, headers, JSON body
--      via @file, output path). This avoids ALL shell quoting and keeps the API
--      key out of the visible process command line.
--   2. Launch `curl -K cfg` with reaper.ExecProcess(cmd, -1) -> detached, returns
--      immediately, never blocks the frame.
--   3. Tell curl to write its own completion marker:
--         --write-out "%output{<done>}%{http_code}"
--      curl writes the HTTP status to <done> only after the transfer finishes
--      (success OR HTTP error OR connection failure -> "000"), so the marker
--      strictly follows the fully-written body/download file.
--   4. net.update(), called once per ImGui frame, polls the marker files and
--      fires each request's on_done callback.
--
-- Requires curl >= 7.73 (for %output{}) — shipped in-box on Windows 10 1803+,
-- macOS, and modern Linux.

local net = {}

local SEP = package.config:sub(1, 1)
local is_win = SEP == "\\"

-- Windows-only launcher. ExecProcess(-1) pops a console window for a console app
-- like curl. wscript.exe is a GUI-subsystem host (no console of its own), and
-- WshShell.Run(cmd, 0, False) runs the command with a HIDDEN window (0),
-- detached (False) — so curl runs in the background with nothing on screen. The
-- command is read from a file to sidestep all nested-quote escaping.
local LAUNCHER_VBS = table.concat({
  'Set fso = CreateObject("Scripting.FileSystemObject")',
  'Set sh = CreateObject("WScript.Shell")',
  'If WScript.Arguments.Count > 0 Then',
  '  Set f = fso.OpenTextFile(WScript.Arguments(0), 1)',
  '  cmd = Trim(f.ReadAll())',
  '  f.Close',
  '  sh.Run cmd, 0, False',
  'End If',
}, "\r\n") .. "\r\n"

local state = {
  curl = nil,
  tmp = nil,
  counter = 0,
  pending = {}, -- list of request handles
}

local function detect_curl()
  local override = reaper.GetExtState("Mirelo", "curl_path")
  -- A '"' would break the launch command's quoting (and can't occur in a valid
  -- Windows path); ignore such an override. We deliberately don't cfg_escape the
  -- path into the command — that doubles backslashes and corrupts normal paths.
  if override ~= nil and override ~= "" and not override:find('"', 1, true) then
    return override
  end
  if is_win then
    return (os.getenv("SystemRoot") or "C:\\Windows") .. "\\System32\\curl.exe"
  end
  -- macOS + Linux ship curl at /usr/bin; ExecProcess does not consult PATH.
  return "/usr/bin/curl"
end

function net.init()
  state.curl = detect_curl()
  state.tmp = reaper.GetResourcePath() .. SEP .. "mirelo_reascript_tmp"
  reaper.RecursiveCreateDirectory(state.tmp, 0)
  if is_win then
    state.launcher = state.tmp .. SEP .. "run_hidden.vbs"
    local f = io.open(state.launcher, "wb")
    if f then
      f:write(LAUNCHER_VBS)
      f:close()
    end
  end
end

-- curl config-file values are double-quoted; escape backslash and quote, and
-- drop CR/LF so a value can't split the line and inject a second -K directive.
local function cfg_escape(s)
  return tostring(s):gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("[\r\n]", "")
end

-- Forward slashes work everywhere for curl file paths and sidestep the
-- backslash-escaping rule inside config-file quotes / %output{}.
local function fwd(path)
  return (path:gsub("\\", "/"))
end

function net.urlencode(s)
  return (tostring(s):gsub("[^%w%-_%.~]", function(c)
    return string.format("%%%02X", c:byte())
  end))
end

-- Returns true on success, false on any open failure (disk full, permissions).
-- Callers must surface the failure gracefully rather than letting it throw — an
-- unhandled error here would kill the whole defer loop.
local function write_file(path, data)
  local f = io.open(path, "wb")
  if not f then return false end
  f:write(data)
  f:close()
  return true
end

local function read_file(path, binary)
  local f = io.open(path, binary and "rb" or "r")
  if not f then return nil end
  local data = f:read("*a")
  f:close()
  return data
end

local function rm(path)
  if path then os.remove(path) end
end

-- opts:
--   method      "GET" | "POST" | "PUT" (default GET)
--   url         string (required)
--   headers     array of "Name: Value" strings
--   body        string body sent verbatim (e.g. JSON)
--   upload_file path to stream as the request body (PUT to signed URL)
--   download_to path to write the response body to (binary download)
--   timeout     seconds (default 60)
--   label       string for diagnostics
--   on_done     function(res) where res = {ok, status, body, error, label}
-- Returns a handle (also pushed onto the pending list).
function net.request(opts)
  state.counter = state.counter + 1
  local id = state.counter
  local base = state.tmp .. SEP .. "req_" .. id
  local cfg_path = base .. ".cfg"
  local done_path = base .. ".done"
  local body_path = opts.download_to or (base .. ".body")
  local req_body_path = nil

  -- A disk-write failure can't reach the network, so report it through the same
  -- callback path as any other failure instead of throwing (which would kill the
  -- defer loop). status 0 routes to the "network/unreachable" copy.
  local function abort(msg)
    if opts.on_done then opts.on_done({ ok = false, status = 0, error = msg, label = opts.label }) end
    return nil
  end

  local lines = {}
  local function add(line) lines[#lines + 1] = line end

  add('url = "' .. cfg_escape(opts.url) .. '"')
  local method = opts.method or "GET"
  add('request = "' .. method .. '"')

  for _, h in ipairs(opts.headers or {}) do
    add('header = "' .. cfg_escape(h) .. '"')
  end

  if opts.body then
    req_body_path = base .. ".reqbody"
    if not write_file(req_body_path, opts.body) then
      return abort("could not write request body (check disk space / permissions)")
    end
    add('data-binary = "@' .. fwd(req_body_path) .. '"')
  elseif opts.upload_file then
    -- The user's own file path; a literal quote in it would otherwise break the
    -- config line (our generated output/done paths can't contain one).
    add('upload-file = "' .. cfg_escape(fwd(opts.upload_file)) .. '"')
  end

  add('output = "' .. fwd(body_path) .. '"')
  add('write-out = "%output{' .. fwd(done_path) .. '}%{http_code}"')
  add("silent")
  add("show-error")
  add("location")              -- follow 3xx (S3 redirects)
  add("max-redirs = 5")
  add("max-time = " .. tostring(opts.timeout or 60))

  if not write_file(cfg_path, table.concat(lines, "\n") .. "\n") then
    rm(req_body_path)
    return abort("could not write request config (check disk space / permissions)")
  end

  -- Best-effort cleanup of any stale marker from a reused id.
  rm(done_path)

  local curl_cmd = '"' .. state.curl .. '" -K "' .. cfg_path .. '"'
  local cmd_path = nil
  if is_win then
    -- Route through wscript so no console window flashes (see LAUNCHER_VBS).
    cmd_path = base .. ".cmd"
    if not write_file(cmd_path, curl_cmd) then
      rm(req_body_path); rm(cfg_path)
      return abort("could not write launcher command (check disk space / permissions)")
    end
    local wscript = (os.getenv("SystemRoot") or "C:\\Windows") .. "\\System32\\wscript.exe"
    local launch = '"' .. wscript .. '" //nologo //B "' .. state.launcher .. '" "' .. cmd_path .. '"'
    reaper.ExecProcess(launch, -1)
  else
    -- No console-window issue off Windows; launch curl directly, detached.
    reaper.ExecProcess(curl_cmd, -1)
  end

  local handle = {
    id = id,
    label = opts.label,
    cfg = cfg_path,
    cmd = cmd_path,
    done = done_path,
    body = body_path,
    req_body = req_body_path,
    is_download = opts.download_to ~= nil,
    started = reaper.time_precise(),
    timeout = (opts.timeout or 60) + 15, -- grace over curl's own max-time
    on_done = opts.on_done,
  }
  state.pending[#state.pending + 1] = handle
  return handle
end

local function finish(handle, res)
  rm(handle.cfg)
  rm(handle.cmd)
  rm(handle.done)
  rm(handle.req_body)
  if not handle.is_download then rm(handle.body) end
  if handle.on_done then
    res.label = handle.label
    handle.on_done(res)
  end
end

-- Poll all in-flight requests. Call exactly once per ImGui frame.
function net.update()
  local batch = state.pending
  local still = {}
  for _, h in ipairs(batch) do
    -- A callback above may have triggered net.reset() (e.g. logout on an auth
    -- error), swapping state.pending out. Stop processing this now-stale batch so
    -- sibling requests don't run on_done and resume a torn-down pipeline.
    if state.pending ~= batch then return end
    local marker = read_file(h.done, false)
    if marker and marker:match("^%d%d%d") then
      local status = tonumber(marker:match("^(%d%d%d)"))
      local body = nil
      if not h.is_download then body = read_file(h.body, true) end
      local ok = status >= 200 and status < 300
      local err = nil
      if not ok then
        err = status == 0 and "no response from server (check your connection)"
          or ("HTTP " .. tostring(status))
      end
      finish(h, { ok = ok, status = status, body = body, error = err })
    elseif reaper.time_precise() - h.started > h.timeout then
      finish(h, {
        ok = false,
        status = 0,
        error = "request timed out (curl missing or no response from server)",
      })
    else
      still[#still + 1] = h
    end
  end
  -- Don't clobber a reset() that ran during this pass (it set pending to {}).
  if state.pending == batch then state.pending = still end
end

-- Abandon all in-flight requests and delete their temp files (called on window
-- close). The detached curl processes are left to exit on their own; we just
-- drop our references and clean up the config/command/body files we wrote.
function net.reset()
  for _, h in ipairs(state.pending) do
    rm(h.cfg)
    rm(h.cmd)
    rm(h.done)
    rm(h.req_body)
    if not h.is_download then rm(h.body) end
  end
  state.pending = {}
end

return net
