-- Mirelo HTTP API. Every call is async: pass a callback cb(err, data, status).
-- err is a string or nil.
--
-- Generation, assets and the account run on v3. Music stays on v2 because there
-- is no music family in v3, and so does /v2/plugin/feedback, which has no v3
-- equivalent — so this module deliberately talks to both versions.

local net = require("mirelo.net")
local json = require("mirelo.json")
local store = require("mirelo.store")
local errors = require("mirelo.errors")

local api = {}

api.PLUGIN_TYPE = "reaper"
api.PLUGIN_VERSION = "1.1.0-reascript"
api.X_CLIENT = "REAPER Plugin v" .. api.PLUGIN_VERSION

-- Set by the UI: invoked when any call fails with an auth error so the app can
-- drop back to the connect screen (centralised re-auth).
api.on_auth_error = nil

-- The v3 model every collection runs. 2.0 arrives as another model id rather
-- than as another API, so this is the only place the version is named.
api.V3_MODEL = "sfx-1.6"

-- Where each generation kind lives. The five that moved name their v3
-- collection path; the two music kinds keep the v2 endpoint/version pair.
api.MODELS = {
  sfx          = { v3 = "/v3/text-to-sfx/generations" },
  video_sfx    = { v3 = "/v3/video-to-sfx/generations" },
  -- Both extends poll one collection: v3 folded the `with_video` route into the
  -- presence of `input.video`.
  extend       = { v3 = "/v3/extend/edits" },
  extend_video = { v3 = "/v3/extend/edits" },
  inpaint      = { v3 = "/v3/inpaint/edits" },
  music        = { v2 = "text-to-music",  version = "v1.0" },
  video_music  = { v2 = "video-to-music", version = "v1.0" },
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

-- One key per create request, so any replay of that request — a redirect curl
-- re-POSTs, a proxy retry — is answered with the original job instead of
-- starting and charging for a second generation. Clicking Generate twice is a
-- second request and still gets a second key, as it should.
--
-- Keys have to differ between two REAPER sessions signed in to the same
-- account: the same key with a different body is a 409, and with the same body
-- it replays the other session's job. os.time() and a counter cannot separate
-- them, since two sessions started in the same second share both, and neither
-- can this table's address — it is not unique across processes, and six loads
-- in one second produced three distinct addresses between them.
--
-- So the generator is seeded from the host's own clock, which is the one value
-- here with real resolution: reaper.time_precise() is a system timestamp in
-- seconds, so its microsecond fraction differs between two sessions unless they
-- reached this line in the same microsecond. Seeded lazily because that call
-- needs the host, and explicitly because math.random only seeds itself from Lua
-- 5.4 on.
local idempotency_seeded = false
local function seed_idempotency()
  if idempotency_seeded then return end
  idempotency_seeded = true
  local address = tonumber(tostring({}):match("0x(%x+)") or "0", 16) or 0
  math.randomseed(os.time() ~ math.floor(reaper.time_precise() * 1e6) ~ address)
end

local idempotency_seq = 0
local function idempotency_headers(auth)
  local h = json_headers(auth)
  seed_idempotency()
  idempotency_seq = idempotency_seq + 1
  h[#h + 1] = string.format("Idempotency-Key: reaper-%08x%08x-%d",
    math.random(0, 0xFFFFFFFF), math.random(0, 0xFFFFFFFF), idempotency_seq)
  return h
end

-- Decode JSON and route failures through the shared error classifier so every
-- call site gets the same friendly, actionable copy as the other plugins.
-- Calls cb(err_message_or_nil, data, status, category). Auth errors also fire
-- api.on_auth_error so the app drops to the connect screen.
local function classify_and_call(cb, res, data)
  local err = data and type(data) == "table" and data.error or nil
  local code = type(err) == "table" and err.code or nil
  local msg = type(err) == "table" and err.message or nil
  -- v3 names the offending request field, which is what lets the banner point
  -- at the input that was wrong rather than at the request as a whole.
  local param = type(err) == "table" and type(err.param) == "string" and err.param or nil
  local v = errors.classify(res.status, code, msg, param)
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
    -- would then index it. Empty 2xx bodies (the storage upload's 204) stay a
    -- normal success.
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

-- cb(err, data) where data = { account_type, id, email, credits_available,
-- spend_capacity, recovery_action, recovery_url, billing_mode }. Every nullable
-- field can arrive as JSON null, which decodes to json.null — callers must
-- type-check rather than test for nil.
function api.me(cb)
  net.request({
    method = "GET",
    url = base() .. "/v3/me",
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

-- cb(err) — a 2xx with empty body is success. No v3 equivalent, so this stays
-- on v2.
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

-- POST a v3 create. cb(err, data) where data carries the job `id`.
local function create_v3(kind, body, cb)
  net.request({
    method = "POST",
    url = base() .. api.MODELS[kind].v3,
    headers = idempotency_headers(true),
    body = json.encode(body),
    timeout = 60,
    label = kind .. "-submit",
    on_done = json_cb(cb),
  })
end

-- POST a v2 jobs create (music only). cb(err, data) where data carries `job_id`.
-- No Idempotency-Key: this path is unchanged from before the v3 move, and v2
-- scopes the header to its sync routes.
local function create_v2(kind, body, cb)
  local model = api.MODELS[kind]
  net.request({
    method = "POST",
    url = base() .. "/v2/" .. model.v2 .. "/" .. model.version .. "/jobs",
    headers = json_headers(true),
    body = json.encode(body),
    timeout = 60,
    label = kind .. "-submit",
    on_done = json_cb(cb),
  })
end

-- kind = "sfx" | "music"; params = { prompt, duration_ms, num_samples }
function api.submit_job(kind, params, cb)
  if kind == "music" then
    return create_v2(kind, {
      prompt = params.prompt,
      duration_ms = params.duration_ms,
      num_samples = params.num_samples or 1,
      format = "mp3",
    }, cb)
  end
  return create_v3(kind, {
    model = api.V3_MODEL,
    duration_ms = params.duration_ms,
    num_variants = params.num_samples or 1,
    input = { prompt = params.prompt },
  }, cb)
end

-- ---- Asset upload (video- and audio-conditioned generation) -------------

-- Step 1: mint an upload ticket. cb(err, data) where data =
-- { id, upload_url, upload_expires_at, max_bytes, fields }. `fields` is what
-- authorizes the upload; treat it as opaque and echo it back.
function api.create_asset(content_type, cb)
  net.request({
    method = "POST",
    url = base() .. "/v3/assets",
    headers = json_headers(true),
    body = json.encode({ content_type = content_type }),
    timeout = 60,
    label = "create-asset",
    on_done = json_cb(cb),
  })
end

-- The upload is storage's request, not Mirelo's, so the shared classifier's copy
-- would blame the wrong thing — a 403 there is an expired policy, not an account
-- without access.
local function upload_message(status)
  if status == 0 then
    return "Couldn't reach the upload server. Check your connection and try again."
  elseif status == 403 then
    return "The upload link expired before the file finished. Try again."
  elseif status == 400 or status == 413 then
    return "Mirelo wouldn't accept that file. Re-export the clip and try again."
  end
  return "The upload failed (HTTP " .. tostring(status) .. "). Try again."
end

-- Step 2: POST the bytes to the presigned URL as multipart/form-data. No
-- Authorization header — the policy in `fields` authorizes the request, and
-- adding one breaks nothing but is not what is checked. `Expect:` is blanked so
-- storage doesn't stall on a 100-continue handshake.
function api.upload_asset(ticket, file_path, cb)
  local form = {}
  for name, value in pairs(ticket.fields or {}) do
    if type(name) == "string" and type(value) == "string" then
      form[#form + 1] = { name = name, value = value }
    end
  end
  -- Sorted only so a request is reproducible: storage requires the file to come
  -- last, and is indifferent to the order the policy fields arrive in.
  table.sort(form, function(a, b) return a.name < b.name end)
  net.request({
    method = "POST",
    url = ticket.upload_url,
    headers = { "Expect:" },
    form = form,
    form_file = file_path,
    timeout = 600,
    label = "upload-asset",
    on_done = function(res)
      if not res.ok then return cb(upload_message(res.status)) end
      cb(nil)
    end,
  })
end

-- Step 3: submit the video job referencing the uploaded asset.
-- kind = "video_sfx" | "video_music"; params = { duration_ms, num_samples }
function api.submit_video(kind, asset_id, params, cb)
  if kind == "video_music" then
    return create_v2(kind, {
      video = { type = "asset", asset_id = asset_id },
      duration_ms = params.duration_ms,
      num_samples = params.num_samples or 1,
      format = "mp3",
    }, cb)
  end
  return create_v3(kind, {
    model = api.V3_MODEL,
    duration_ms = params.duration_ms,
    num_variants = params.num_samples or 1,
    input = { video = { type = "asset", id = asset_id } },
  }, cb)
end

-- ---- Audio-native generation (extender / inpainter) --------------------
-- Both take a pre-uploaded audio asset (read off the selected clip's source).

-- params = { append_duration_ms, num_samples, loop }
function api.submit_extend(asset_id, params, cb)
  local body = {
    model = api.V3_MODEL,
    append_duration_ms = params.append_duration_ms,
    num_variants = params.num_samples or 1,
    input = { audio = { type = "asset", id = asset_id } },
  }
  if params.loop ~= nil then body.controls = { loop = params.loop } end
  return create_v3("extend", body, cb)
end

-- Video-conditioned extend. params = { append_duration_ms, num_samples }
-- The rendered clip starts where the audio prefix starts, so `start_offset_ms`
-- keeps its schema default of 0.
function api.submit_extend_video(audio_asset_id, video_asset_id, params, cb)
  return create_v3("extend_video", {
    model = api.V3_MODEL,
    append_duration_ms = params.append_duration_ms,
    num_variants = params.num_samples or 1,
    input = {
      audio = { type = "asset", id = audio_asset_id },
      video = { type = "asset", id = video_asset_id },
    },
  }, cb)
end

-- params = { segment_start_ms, segment_end_ms, num_samples }
function api.submit_inpaint(asset_id, params, cb)
  return create_v3("inpaint", {
    model = api.V3_MODEL,
    region = { start_ms = params.segment_start_ms, end_ms = params.segment_end_ms },
    num_variants = params.num_samples or 1,
    input = { audio = { type = "asset", id = asset_id } },
  }, cb)
end

function api.poll_job(kind, job_id, cb)
  local model = api.MODELS[kind]
  local url
  if model.v3 then
    url = base() .. model.v3 .. "/" .. net.urlencode(job_id)
  else
    url = base() .. "/v2/" .. model.v2 .. "/" .. model.version .. "/jobs/" .. net.urlencode(job_id)
  end
  net.request({
    method = "GET",
    url = url,
    headers = headers(true),
    timeout = 30,
    label = kind .. "-poll",
    on_done = json_cb(cb),
  })
end

-- ---- v3 job body reading ------------------------------------------------

-- Seconds between local time and UTC, computed once. os.time() reads a date
-- table as local time and v3 stamps every timestamp in UTC.
local UTC_OFFSET = (function()
  local now = os.time()
  local utc = os.date("!*t", now)
  utc.isdst = false
  return os.difftime(now, os.time(utc))
end)()

-- An ISO-8601 UTC timestamp as a Unix epoch, or nil if it isn't one.
local function iso_epoch(text)
  if type(text) ~= "string" then return nil end
  local y, mo, d, h, mi, s = text:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)")
  if not y then return nil end
  return os.time({
    year = tonumber(y), month = tonumber(mo), day = tonumber(d),
    hour = tonumber(h), min = tonumber(mi), sec = tonumber(s), isdst = false,
  }) + UTC_OFFSET
end

-- The file extension for a v3 format token.
--
-- A token names a container and, on the lossy ones, a bitrate — `mp3_320`,
-- `m4a_192` — so it is not itself an extension. The container is, and it is the
-- part before the underscore. An unknown token answers nil, leaving the caller
-- to fall back to the URL.
local CONTAINER_EXT = { wav = "wav", flac = "flac", mp3 = "mp3", m4a = "m4a" }
local function format_ext(format)
  if type(format) ~= "string" then return nil end
  return CONTAINER_EXT[format:match("^[^_]+")]
end

-- The audio a finished v3 job can actually hand over.
--
-- Two result shapes: text-to-sfx, extend and inpaint answer a single
-- `result.output`, while video-to-sfx answers a `result.outputs` list. Inside an
-- output every variant carries its own status and `files` is null when it
-- failed, so a variant existing is not a variant you can use — which is also
-- what makes a `partially_succeeded` job usable instead of a total loss.
--
-- Each entry keeps its output/variant position so a re-poll can find the same
-- file again, `expires_at` as an epoch so a caller can tell a dead download link
-- from a broken download, and `ext` for naming the file on disk.
-- A finished job's outputs as a list, whichever of the two shapes it used.
-- `outputs` is checked against the null sentinel as well as its type, so a body
-- carrying an explicit null there cannot shadow a real `output`.
local function result_outputs(data)
  local result = type(data) == "table" and type(data.result) == "table" and data.result or nil
  if not result then return {} end
  if type(result.outputs) == "table" and result.outputs ~= json.null then return result.outputs end
  if type(result.output) == "table" and result.output ~= json.null then return { result.output } end
  return {}
end

function api.result_files(data)
  local outputs = result_outputs(data)
  local files = {}
  for _, output in ipairs(outputs) do
    if type(output) == "table" then
      for _, variant in ipairs(type(output.variants) == "table" and output.variants or {}) do
        local audio = nil
        if type(variant) == "table" and variant.status == "succeeded" and type(variant.files) == "table" then
          audio = variant.files.audio
        end
        if type(audio) == "table" and type(audio.url) == "string" then
          files[#files + 1] = {
            url = audio.url,
            expires_at = iso_epoch(audio.url_expires_at),
            ext = format_ext(audio.format),
            output_index = tonumber(output.index) or 0,
            index = tonumber(variant.index) or 0,
          }
        end
      end
    end
  end
  return files
end

-- How many variants the job was asked for, summed over its outputs.
--
-- Worth reading rather than assuming the request's own count: billing is on the
-- requested count whatever came back, so this is what a shortfall has to be
-- measured against. `variants_requested` is the only field that says how many
-- were attempted - comparing against the length of `variants` misses a variant
-- the model never produced, which is simply absent from the list.
function api.result_variants_requested(data)
  local total = 0
  for _, output in ipairs(result_outputs(data)) do
    if type(output) == "table" then total = total + (tonumber(output.variants_requested) or 0) end
  end
  return total
end

-- The same file after a re-poll, matched on the position it was found at.
function api.result_file_at(data, output_index, variant_index)
  for _, file in ipairs(api.result_files(data)) do
    if file.output_index == output_index and file.index == variant_index then return file end
  end
  return nil
end

-- What a v3 job says went wrong, as user-facing copy, or nil if it said nothing.
-- `errors` carries one entry per failed output or variant, so the first entry is
-- the failure and the rest are the same thing on sibling variants.
function api.job_failure(data)
  local list = type(data) == "table" and type(data.errors) == "table" and data.errors or nil
  local first = list and list[1] or nil
  if type(first) ~= "table" then return nil end
  return errors.for_job(first.code, first.message).message
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
