-- Async render of a timeline range to MP4 (for video->SFX/Music), ported from
-- the Electron build's mirelo-agent.lua start_render/finalize_render.
--
-- REAPER runs the render on a later main-thread cycle (after our defer callback
-- returns), so we must NOT restore render settings synchronously. We fire the
-- render, then poll for the output file across frames; once it appears and stops
-- growing we restore the user's render settings + time selection and call back.
--
-- Needs FFmpeg installed in REAPER (the MP4/H.264 encoder). Script-render audio
-- comes out silent, but video->SFX only needs the rendered VIDEO frames, so that
-- limitation doesn't matter here.

local SEP = package.config:sub(1, 1)

-- REAPER's RENDER_FORMAT config for MP4/H.264 (FFmpeg), captured from a real
-- project — the exact value GetSetProjectInfo_String round-trips. Forcing it
-- means the user never has to set the render format by hand. (Verbatim from the
-- production agent, which renders video->SFX end-to-end with it.)
local MP4_RENDER_FORMAT = "IEZNVwAAAAAAAAAAAAgAAAAAAACAAAAAgAcAADgEAAAAAPBBAQAAAF8AAAAAAA=="

-- Just under the typical render RPC budget so a slow render fails cleanly with a
-- settings restore rather than hanging.
local RENDER_TIMEOUT = 170
-- Wall-clock dwell the output size must hold steady before we treat the render
-- as finished. Frame counting is unreliable across frame rates and lets a slow
-- disk's write buffer look "done" mid-write, uploading a truncated MP4.
local RENDER_STABLE_SECS = 0.5

local render = {}
local pending = nil -- one render at a time
local counter = 0

local function parent_dir(path) return path:match("^(.*)[/\\][^/\\]+$") end

local function file_size(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local size = f:seek("end")
  f:close()
  return size
end

function render.tmp_mp4()
  counter = counter + 1
  local dir = reaper.GetResourcePath() .. SEP .. "mirelo_reascript_tmp" .. SEP .. "render"
  reaper.RecursiveCreateDirectory(dir, 0)
  return dir .. SEP .. "render_" .. os.time() .. "_" .. counter .. ".mp4"
end

local function restore(save)
  local proj = 0
  reaper.GetSetProjectInfo(proj, "RENDER_BOUNDSFLAG", save.bounds, true)
  reaper.GetSetProjectInfo(proj, "RENDER_ADDTOPROJ", save.addtoproj, true)
  reaper.GetSetProjectInfo(proj, "RENDER_SETTINGS", save.settings, true)
  reaper.GetSetProjectInfo_String(proj, "RENDER_FILE", save.file, true)
  reaper.GetSetProjectInfo_String(proj, "RENDER_PATTERN", save.pat, true)
  reaper.GetSetProjectInfo_String(proj, "RENDER_FORMAT", save.format, true)
  reaper.GetSet_LoopTimeRange(true, false, save.ts0, save.ts1, false)
end

-- on_done(err, out_file, duration_seconds)
function render.start(out_file, start_sec, end_sec, on_done)
  if pending then return on_done("a render is already in progress") end
  if not (start_sec and end_sec) or end_sec <= start_sec then
    return on_done("invalid render range")
  end
  local proj = 0

  local save = {}
  save.ts0, save.ts1 = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
  save.bounds = reaper.GetSetProjectInfo(proj, "RENDER_BOUNDSFLAG", 0, false)
  save.addtoproj = reaper.GetSetProjectInfo(proj, "RENDER_ADDTOPROJ", 0, false)
  save.settings = reaper.GetSetProjectInfo(proj, "RENDER_SETTINGS", 0, false)
  _, save.file = reaper.GetSetProjectInfo_String(proj, "RENDER_FILE", "", false)
  _, save.pat = reaper.GetSetProjectInfo_String(proj, "RENDER_PATTERN", "", false)
  _, save.format = reaper.GetSetProjectInfo_String(proj, "RENDER_FORMAT", "", false)

  -- Wrap the mutations so a thrown REAPER call still restores settings.
  local ok, err = pcall(function()
    os.remove(out_file) -- write this exact name, no auto-increment

    -- RENDER_FILE is the directory; RENDER_PATTERN is the stem (REAPER re-adds
    -- the extension). A full path as RENDER_FILE makes a folder instead.
    local dir = parent_dir(out_file) or ""
    local name = out_file:match("[^/\\]+$") or out_file
    local stem = name:gsub("%.[^.]+$", "")

    reaper.GetSet_LoopTimeRange(true, false, start_sec, end_sec, false)
    reaper.GetSetProjectInfo(proj, "RENDER_BOUNDSFLAG", 2, true) -- 2 = time selection
    reaper.GetSetProjectInfo(proj, "RENDER_ADDTOPROJ", 0, true)  -- our import places it
    reaper.GetSetProjectInfo_String(proj, "RENDER_FILE", dir, true)
    reaper.GetSetProjectInfo_String(proj, "RENDER_PATTERN", stem, true)
    reaper.GetSetProjectInfo_String(proj, "RENDER_FORMAT", MP4_RENDER_FORMAT, true)
  end)
  if not ok then
    restore(save)
    return on_done("render setup failed: " .. tostring(err))
  end

  pending = {
    out = out_file,
    on_done = on_done,
    save = save,
    duration = end_sec - start_sec,
    deadline = os.time() + RENDER_TIMEOUT,
    last_size = -1,
    stable_since = 0,
  }

  -- Offline render is silent if REAPER idled the audio engine while backgrounded;
  -- force the device open first (irrelevant to video frames, harmless otherwise).
  reaper.Audio_Init()
  -- 42230 = render with most recent settings, auto-close dialog (no popup).
  reaper.Main_OnCommand(42230, 0)
end

-- Call once per frame.
function render.update()
  if not pending then return end
  local p = pending
  local size = file_size(p.out)

  if size and size > 0 then
    if size ~= p.last_size then
      p.last_size = size
      p.stable_since = reaper.time_precise()
      return
    end
    -- Size held steady; require a wall-clock dwell before declaring it done.
    if reaper.time_precise() - p.stable_since < RENDER_STABLE_SECS then return end
    restore(p.save)
    pending = nil
    p.on_done(nil, p.out, p.duration)
    return
  end

  if os.time() > p.deadline then
    restore(p.save)
    pending = nil
    p.on_done("render produced no MP4 — install FFmpeg in REAPER and make sure the range covers a video clip")
  end
end

-- Restore settings + abandon any in-flight render (called on shutdown).
function render.abort()
  if not pending then return end
  restore(pending.save)
  pending = nil
end

return render
