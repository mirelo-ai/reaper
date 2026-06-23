-- Mirelo HTTP API, transcribed 1:1 from the Electron/SDK build's network calls
-- (apps/plugins/reaper-plugin/src/main/* and packages/sdk-node/*). Every call is
-- async: pass a callback cb(err, data, status). err is a string or nil.

local net = require("mirelo.net")
local json = require("mirelo.json")
local store = require("mirelo.store")
local errors = require("mirelo.errors")

local api = {}

api.PLUGIN_TYPE = "reaper"
api.PLUGIN_VERSION = "1.0.0-reascript"
api.X_CLIENT = "REAPER Plugin v" .. api.PLUGIN_VERSION

-- Set by the UI: invoked when any call fails with an auth error so the app can
-- drop back to the connect screen (centralised re-auth).
api.on_auth_error = nil

-- Model versions match the Electron build's constants.
api.MODELS = {
  sfx          = { endpoint = "text-to-sfx",             version = "v1.6" },
  music        = { endpoint = "text-to-music",           version = "v1.0" },
  video_sfx    = { endpoint = "video-to-sfx",            version = "v1.6" },
  video_music  = { endpoint = "video-to-music",          version = "v1.0" },
  extend       = { endpoint = "extend-audio",            version = "v1.6" },
  extend_video = { endpoint = "extend-audio/with_video", version = "v1.6" },
  inpaint      = { endpoint = "inpaint-audio",           version = "v1.6" },
}

local function base() return store.api_base() end

local function headers(auth)
  local h = { "x-client: " .. api.X_CLIENT }
  if auth then
    local key = store.api_key()
    if key then h[#h + 1] = "Authorization: Bearer " .. key end
  end
  return h
end

local function json_headers(auth)
  local h = headers(auth)
  h[#h + 1] = "Content-Type: application/json"
  return h
end

-- Decode JSON and route failures through the shared error classifier so every
-- call site gets the same friendly, actionable copy as the other plugins.
-- Calls cb(err_message_or_nil, data, status, category). Auth errors also fire
-- api.on_auth_error so the app drops to the connect screen.
local function classify_and_call(cb, res, data)
  local code = data and type(data) == "table" and data.error and data.error.code or nil
  local msg = data and type(data) == "table" and data.error and data.error.message or nil
  local v = errors.classify(res.status, code, msg)
  -- Auth failures fire the teardown hook (logout + gen.reset). We STILL invoke
  -- the caller's callback so its per-request cleanup runs (e.g. fetch_me clearing
  -- M.me_inflight, the feedback modal clearing "Sending..."). generation's fail()
  -- is guarded by gen.is_busy(), so a stale job's callback can't resurrect an
  -- error banner after the reset.
  if v.category == "auth" and api.on_auth_error then api.on_auth_error() end
  return cb(v.message, data, res.status, v.category)
end

local function json_cb(cb)
  return function(res)
    -- json.decode is internally pcall-guarded: it returns nil (never throws) on
    -- a non-JSON / truncated body, so a CDN HTML error page can't crash the loop.
    local data = nil
    if res.body and #res.body > 0 then data = json.decode(res.body) end
    if res.status == 0 or not res.ok then
      return classify_and_call(cb, res, data)
    end
    -- A 2xx whose non-empty body didn't parse (proxy HTML, truncated transfer):
    -- treat as a server error rather than handing nil data to a caller that
    -- would then index it. Empty 2xx bodies (S3 PUT) stay a normal success.
    if res.body and #res.body > 0 and data == nil then
      return cb("Mirelo returned an unreadable response. Please try again.", nil, res.status, "server")
    end
    return cb(nil, data, res.status)
  end
end

-- ---- Auth (device-nonce handshake) --------------------------------------

function api.create_nonce(cb)
  net.request({
    method = "POST",
    url = base() .. "/plugin/create-nonce",
    headers = json_headers(false),
    body = json.encode({ pluginType = api.PLUGIN_TYPE, pluginVersion = api.PLUGIN_VERSION }),
    timeout = 30,
    label = "create-nonce",
    on_done = json_cb(cb),
  })
end

function api.poll_nonce(nonce, cb)
  net.request({
    method = "GET",
    url = base() .. "/plugin/poll-nonce?nonce=" .. net.urlencode(nonce),
    headers = headers(false),
    timeout = 30,
    label = "poll-nonce",
    on_done = json_cb(cb),
  })
end

-- The web approval page the user opens to bless the nonce.
function api.connect_url(nonce)
  return "https://mirelo.ai/studio/connect-plugin?nonce=" .. net.urlencode(nonce)
end

-- ---- Account ------------------------------------------------------------

function api.me(cb)
  net.request({
    method = "GET",
    url = base() .. "/v2/me",
    headers = headers(true),
    timeout = 30,
    label = "me",
    on_done = json_cb(cb),
  })
end

-- ---- Version gate + feedback --------------------------------------------

-- cb(err, data) where data = { message, blocked, updateUrl }.
function api.check_version(cb)
  net.request({
    method = "POST",
    url = base() .. "/plugin/check-version",
    headers = json_headers(false),
    body = json.encode({ pluginType = api.PLUGIN_TYPE, pluginVersion = api.PLUGIN_VERSION }),
    timeout = 30,
    label = "check-version",
    on_done = json_cb(cb),
  })
end

-- cb(err) — a 2xx with empty body is success.
function api.submit_feedback(message, cb)
  net.request({
    method = "POST",
    url = base() .. "/v2/plugin/feedback",
    headers = json_headers(true),
    body = json.encode({
      message = message,
      plugin_type = api.PLUGIN_TYPE,
      plugin_version = api.PLUGIN_VERSION,
    }),
    timeout = 30,
    label = "feedback",
    on_done = json_cb(function(err) cb(err) end),
  })
end

-- ---- Generation ---------------------------------------------------------

-- kind = "sfx" | "music"; params = { prompt, duration_ms, num_samples }
function api.submit_job(kind, params, cb)
  local model = api.MODELS[kind]
  local body = {
    prompt = params.prompt,
    duration_ms = params.duration_ms,
    num_samples = params.num_samples or 1,
  }
  if kind == "music" then body.format = "mp3" end
  net.request({
    method = "POST",
    url = base() .. "/v2/" .. model.endpoint .. "/" .. model.version .. "/jobs",
    headers = json_headers(true),
    body = json.encode(body),
    timeout = 60,
    label = kind .. "-submit",
    on_done = json_cb(cb),
  })
end

-- ---- Asset upload (video-conditioned generation) -----------------------

-- Step 1: reserve an asset + get a pre-signed S3 upload URL.
function api.create_asset(content_type, cb)
  net.request({
    method = "POST",
    url = base() .. "/v2/assets",
    headers = json_headers(true),
    body = json.encode({ content_type = content_type }),
    timeout = 60,
    label = "create-asset",
    on_done = json_cb(cb),
  })
end

-- Step 2: PUT the file bytes straight to the pre-signed URL (no auth header —
-- the signature covers the request; adding Authorization breaks it). `Expect:`
-- is blanked so S3 doesn't stall on a 100-continue handshake.
function api.upload_asset(upload_url, file_path, content_type, cb)
  net.request({
    method = "PUT",
    url = upload_url,
    upload_file = file_path,
    headers = { "Content-Type: " .. content_type, "Expect:" },
    timeout = 600,
    label = "upload-asset",
    on_done = function(res)
      if not res.ok then return cb(errors.classify(res.status).message) end
      cb(nil)
    end,
  })
end

-- Step 3: submit the video job referencing the uploaded asset.
-- kind = "video_sfx" | "video_music"; params = { duration_ms, num_samples }
function api.submit_video(kind, asset_id, params, cb)
  local model = api.MODELS[kind]
  local body = {
    video = { type = "asset", asset_id = asset_id },
    duration_ms = params.duration_ms,
    num_samples = params.num_samples or 1,
  }
  if kind == "video_music" then body.format = "mp3" end
  net.request({
    method = "POST",
    url = base() .. "/v2/" .. model.endpoint .. "/" .. model.version .. "/jobs",
    headers = json_headers(true),
    body = json.encode(body),
    timeout = 60,
    label = kind .. "-submit",
    on_done = json_cb(cb),
  })
end

-- ---- Audio-native generation (extender / inpainter) --------------------
-- Both take a pre-uploaded audio asset (read off the selected clip's source).

-- params = { append_duration_ms, num_samples, loop }
function api.submit_extend(asset_id, params, cb)
  local model = api.MODELS.extend
  local body = {
    audio = { type = "asset", asset_id = asset_id },
    append_duration_ms = params.append_duration_ms,
    num_samples = params.num_samples or 1,
  }
  if params.loop ~= nil then body.loop = params.loop end
  net.request({
    method = "POST",
    url = base() .. "/v2/" .. model.endpoint .. "/" .. model.version .. "/jobs",
    headers = json_headers(true),
    body = json.encode(body),
    timeout = 60,
    label = "extend-submit",
    on_done = json_cb(cb),
  })
end

-- Video-conditioned extend. params = { append_duration_ms, num_samples }
function api.submit_extend_video(audio_asset_id, video_asset_id, params, cb)
  local model = api.MODELS.extend_video
  local body = {
    audio = { type = "asset", asset_id = audio_asset_id },
    video = { type = "asset", asset_id = video_asset_id },
    append_duration_ms = params.append_duration_ms,
    start_offset_ms = 0,
    num_samples = params.num_samples or 1,
  }
  net.request({
    method = "POST",
    url = base() .. "/v2/" .. model.endpoint .. "/" .. model.version .. "/jobs",
    headers = json_headers(true),
    body = json.encode(body),
    timeout = 60,
    label = "extend-video-submit",
    on_done = json_cb(cb),
  })
end

-- params = { segment_start_ms, segment_end_ms, num_samples }
function api.submit_inpaint(asset_id, params, cb)
  local model = api.MODELS.inpaint
  local body = {
    audio = { type = "asset", asset_id = asset_id },
    segment = { start_ms = params.segment_start_ms, end_ms = params.segment_end_ms },
    num_samples = params.num_samples or 1,
  }
  net.request({
    method = "POST",
    url = base() .. "/v2/" .. model.endpoint .. "/" .. model.version .. "/jobs",
    headers = json_headers(true),
    body = json.encode(body),
    timeout = 60,
    label = "inpaint-submit",
    on_done = json_cb(cb),
  })
end

function api.poll_job(kind, job_id, cb)
  local model = api.MODELS[kind]
  net.request({
    method = "GET",
    url = base() .. "/v2/" .. model.endpoint .. "/" .. model.version .. "/jobs/" .. net.urlencode(job_id),
    headers = headers(true),
    timeout = 30,
    label = kind .. "-poll",
    on_done = json_cb(cb),
  })
end

-- Result URLs are pre-signed S3 links: no auth header, just GET to disk.
function api.download(url, dest, cb)
  net.request({
    method = "GET",
    url = url,
    headers = {}, -- pre-signed; adding Authorization can break the signature
    download_to = dest,
    timeout = 300,
    label = "download",
    on_done = function(res)
      if not res.ok then return cb(errors.classify(res.status).message) end
      cb(nil)
    end,
  })
end

return api
