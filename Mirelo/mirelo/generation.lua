-- Generation orchestrator. Pipelines share one tail (poll -> download -> result
-- cards). One active job at a time. The UI reads gen.state each frame; every
-- transition is driven by api/render callbacks + gen.update(), never blocking.
--   text    : submit -> poll -> download
--   video   : render range -> asset -> upload -> submit -> poll -> download
--   extend  : slice prefix WAV -> asset -> upload -> submit -> poll -> download
--   inpaint : upload whole clip + segment -> submit -> poll -> download
-- Placement (Add-to-track) is deferred to gen.place(item) per the placement ctx.

local api = require("mirelo.api")
local net = require("mirelo.net")
local render = require("mirelo.render")
local wav = require("mirelo.wav")
local R = require("mirelo.reaper_io")

local POLL_INTERVAL = 2.0
-- Give up polling a job that never reaches a terminal state, so a stuck backend
-- job can't leave the UI on "Generating…" forever.
local POLL_TIMEOUT_SEC = 600
local TOTAL_MAX_SEC = 60 -- extend: prefix + new audio cap (SFX_EXTEND_LIMITS v1.6)

local gen = {}
gen.history = {} -- result cards accumulated across generations (cleared on logout)
local counter = 0
local next_id = 0
local next_batch = 0
-- Bumped on every reset() (new generation OR logout). Each job captures the
-- epoch at start; its async callbacks bail when it changes, so a torn-down or
-- superseded job can't mutate state, delete a newer job's temps, or call the API.
local epoch = 0
local cleanup_temps -- forward declaration; defined below
local discard_files -- forward declaration; defined alongside gen.remove below

-- Trim a card label (e.g. a long prompt) to keep result cards tidy.
local function truncate(s, n)
  s = (s or ""):gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")
  if #s <= n then return s end
  return s:sub(1, n) .. "..."
end

local AUDIO_MIME = {
  wav = "audio/wav", wave = "audio/wav", mp3 = "audio/mpeg", m4a = "audio/mp4",
  aac = "audio/mp4", ogg = "audio/ogg", oga = "audio/ogg", opus = "audio/opus",
  flac = "audio/flac", aiff = "audio/aiff", aif = "audio/aiff",
}
local function audio_content_type(ext) return AUDIO_MIME[ext or ""] or "application/octet-stream" end

-- Maps a generation kind to the UI tab it belongs under, so the results history
-- can be shown per-tab (each tool lists only its own outputs, like DaVinci).
local MODE_GROUP = {
  sfx = "sfx", video_sfx = "sfx",
  music = "music", video_music = "music",
  extend = "extend", extend_video = "extend",
  inpaint = "inpaint",
}

gen.state = {
  status = "idle", -- idle | rendering | uploading | submitting | polling | downloading | done | error
  kind = nil,      -- sfx | music | video_sfx | video_music | extend | inpaint
  is_music = false,
  progress = 0,
  message = "",
  job_id = nil,
  results = {},
  error = nil,
  captured_pos = 0,
  num_samples = 1,
  place_ctx = nil, -- { mode="cursor"|"inpaint", pos, clip_in?, clip_out? }
  _next_poll = 0,
  _poll_deadline = 0,
  _poll_inflight = false,
  _dl_total = 0,
  _dl_done = 0,
  _dl_failed = 0,
  _undelivered = 0,
  _render_file = nil,
  _upload_file = nil,
}

local function reset(kind, is_music)
  epoch = epoch + 1 -- invalidate any in-flight job's async callbacks
  local s = gen.state
  s.status = "idle"; s.kind = kind; s.is_music = is_music or false
  s.progress = 0; s.message = ""; s.job_id = nil; s.results = {}; s.error = nil
  s.place_ctx = nil
  s.active_clip = nil -- clip snapshot shown by the extender/inpainter while busy
  s._hl = nil; s._original = nil; s._pair = nil
  s.label = nil; s.place_name = nil; s._name_from_output = false
  s._next_poll = 0; s._poll_deadline = 0; s._poll_inflight = false
  s._dl_total = 0; s._dl_done = 0; s._dl_failed = 0; s._undelivered = 0
  s._render_file = nil; s._upload_file = nil
end
-- Full reset (logout): GC the temp downloads we still own, then drop history.
gen.reset = function()
  render.abort()  -- an in-flight video render would otherwise resume into a nil-kind state
  cleanup_temps() -- drop the in-flight render/upload temps before reset nulls their paths
  -- GC downloads we own: results already promoted to history, plus any from a
  -- batch still mid-download (in s.results, which reset is about to clear).
  for _, r in ipairs(gen.state.results) do discard_files(r) end
  for _, r in ipairs(gen.history) do discard_files(r) end
  gen.history = {}
  reset(nil, false)
end

function gen.is_busy()
  local st = gen.state.status
  return st == "rendering" or st == "uploading" or st == "submitting"
    or st == "polling" or st == "downloading"
end

local function out_dir()
  local sep = package.config:sub(1, 1)
  local dir = reaper.GetResourcePath() .. sep .. "mirelo_reascript_tmp" .. sep .. "out"
  reaper.RecursiveCreateDirectory(dir, 0)
  return dir, sep
end

local function tmp_path(prefix, ext)
  local dir, sep = out_dir()
  counter = counter + 1
  return string.format("%s%s%s_%s_%d.%s", dir, sep, prefix, os.time(), counter, ext)
end

cleanup_temps = function()
  local s = gen.state
  if s._render_file then os.remove(s._render_file); s._render_file = nil end
  if s._upload_file then os.remove(s._upload_file); s._upload_file = nil end
end

local function fail(msg)
  -- A torn-down job (logout/reset set status to idle) must not resurrect an
  -- error banner when its late callback finally returns an error.
  if not gen.is_busy() then return end
  cleanup_temps()
  gen.state.status = "error"
  gen.state.error = msg
  gen.state.message = msg
end

local function ext_from_url(url)
  local path = url:gsub("%?.*$", "")
  local ext = path:match("%.([%w]+)$")
  if ext and #ext <= 4 then return ext:lower() end
  return "wav"
end

-- Music is the one family v3 has no equivalent for, so its jobs are still v2
-- jobs: a different create field for the id, and a different poll body.
local function is_v3_kind(kind)
  local model = kind and api.MODELS[kind] or nil
  return model ~= nil and model.v3 ~= nil
end

-- v3 answers a create with the job envelope's `id`; v2 with `job_id`.
local function job_id_of(data)
  if type(data) ~= "table" then return nil end
  local id = data.id or data.job_id
  return type(id) == "string" and id or nil
end

-- A usable upload ticket: the id the generation will reference, the URL to POST
-- to, and the policy fields that authorize it.
local function asset_ticket(data)
  if type(data) ~= "table" then return nil end
  if type(data.id) ~= "string" or type(data.upload_url) ~= "string" then return nil end
  if type(data.fields) ~= "table" then return nil end
  return data
end

-- files: entries as api.result_files describes them — url, and optionally ext,
-- expires_at and the output/variant position it was found at.
local function start_downloads(files)
  local s = gen.state
  local job = epoch
  s.status = "downloading"
  s.message = "Downloading…"
  s._dl_total = #files
  s._dl_done = 0
  s._dl_failed = 0
  local stamp = tostring(os.time())
  for i, file in ipairs(files) do
    counter = counter + 1
    local dir, sep = out_dir()
    local dest = string.format("%s%smirelo_%s_%s_%d.%s", dir, sep, s.kind, stamp, counter,
      file.ext or ext_from_url(file.url))
    local refreshed = false

    local function settle(derr)
      s._dl_done = s._dl_done + 1
      if not derr then
        next_id = next_id + 1
        -- Card label: the generated file's name for source-less gens (video),
        -- otherwise the prepared label (prompt / source name).
        local nm = s._name_from_output and (dest:match("[^/\\]+$"))
          or (s.num_samples > 1 and (s.label .. " " .. i) or s.label)
        s.results[#s.results + 1] = {
          id = next_id, path = dest, url = file.url, index = i, hi = s._hl, place = s.place_ctx,
          place_name = s.place_name, pair = s._pair, name = nm, mode = MODE_GROUP[s.kind] or "sfx",
        }
      else
        s._dl_failed = s._dl_failed + 1
        os.remove(dest) -- curl may have written an error body (e.g. an S3 403 XML)
      end
      s.progress = 90 + math.floor(10 * s._dl_done / s._dl_total)
      if s._dl_done >= s._dl_total then
        if #s.results == 0 then
          fail("all sample downloads failed")
        else
          -- Before/after: surface the original clip as the leading comparison card.
          if s._original then
            next_id = next_id + 1
            table.insert(s.results, 1, {
              id = next_id, path = s._original.path, name = s._original.name,
              index = 0, hi = s._hl, place = s.place_ctx, pair = s._pair, original = true,
              mode = MODE_GROUP[s.kind] or "inpaint",
            })
          end
          -- Prepend this batch to the persistent history (newest generation on top).
          for j = #s.results, 1, -1 do
            table.insert(gen.history, 1, s.results[j])
          end
          s.status = "done"; s.progress = 100; s.message = "Done"
        end
      end
    end

    local function attempt(url)
      api.download(url, dest, function(derr)
        -- Bail if this batch was torn down (logout) or superseded by a newer job.
        -- The epoch check also covers the case where a sibling download already
        -- failed (status left "error") while others were still in flight.
        if epoch ~= job then
          os.remove(dest) -- the file may have landed; no card will reference it
          return
        end
        -- A link that has already died is recoverable rather than a lost sample:
        -- v3 times url_expires_at from the read, so polling the job again
        -- re-signs it. Once per file, so a download failing for any other reason
        -- cannot loop.
        if derr and not refreshed and file.expires_at and os.time() >= file.expires_at then
          refreshed = true
          return api.poll_job(s.kind, s.job_id, function(perr, pdata)
            if epoch ~= job then
              os.remove(dest)
              return
            end
            local fresh = (not perr) and api.result_file_at(pdata, file.output_index, file.index) or nil
            if not fresh then return settle(derr) end
            attempt(fresh.url)
          end)
        end
        settle(derr)
      end)
    end

    attempt(file.url)
  end
end

-- Statuses a v3 job can end on with no audio, and what to say when the job
-- itself reported nothing about why.
local V3_DEAD_END = {
  failed = "generation failed",
  canceled = "the generation was canceled",
  expired = "the generation expired before it finished — please try again",
}

local function handle_v3_poll(data)
  local s = gen.state
  local status = data.status
  if status == "succeeded" or status == "partially_succeeded" then
    -- partially_succeeded means some variants came back and some did not, so
    -- show the samples that worked instead of dropping the whole batch.
    local files = api.result_files(data)
    if #files == 0 then
      return fail(api.job_failure(data) or "job succeeded but returned no audio")
    end
    -- The shortfall has to be counted here, not inferred from the cards: the
    -- job is billed on the count that was asked for whatever came back, so a
    -- batch that quietly returns fewer is audio the user paid for and is not
    -- told about. Downloads that then fail are counted separately.
    s._undelivered = math.max(0, api.result_variants_requested(data) - #files)
    cleanup_temps()
    s.progress = 90
    return start_downloads(files)
  end
  local dead_end = V3_DEAD_END[status]
  if dead_end then return fail(api.job_failure(data) or dead_end) end
  -- The status list is open and a state we don't recognise has to keep polling
  -- rather than fail, because a new one marks a pipeline stage rather than a new
  -- outcome. `completed_at` is what catches the other case: it is null while a
  -- job is queued or running and a timestamp once it is final, so a job that
  -- finished under a name this build doesn't know stops here instead of running
  -- the poll deadline down.
  if type(data.completed_at) == "string" then
    return fail(api.job_failure(data)
      or "the generation finished in a state this version doesn't understand — please update the plugin")
  end
  if reaper.time_precise() > s._poll_deadline then
    return fail("generation timed out — please try again")
  end
  -- v3 reports progress as a 0..1 fraction, and drops it once the job is final.
  if type(data.progress) == "number" then
    s.progress = math.max(s.progress, math.min(89, math.floor(data.progress * 89)))
  end
  s._next_poll = reaper.time_precise() + POLL_INTERVAL
end

-- Music only: one flat list of URLs and a whole-number percent.
local function handle_v2_poll(data)
  local s = gen.state
  local status = data.status
  if status == "succeeded" or status == "completed" then
    local urls = (data.result and data.result.result_urls) or data.result_urls
    if not urls or #urls == 0 then return fail("job succeeded but returned no audio") end
    cleanup_temps()
    s.progress = 90
    -- Deliberately no expires_at: v2 states no link lifetime, and that absence
    -- is what keeps these files out of the expired-link refresh, which re-polls
    -- and matches on an output/variant position a v2 result does not have. Give
    -- one of these an expiry and the refresh would fire and never match.
    local files = {}
    for i, url in ipairs(urls) do files[i] = { url = url } end
    return start_downloads(files)
  end
  if status == "errored" or status == "failed" then
    return fail((data.error and data.error.message) or "generation failed")
  end
  if reaper.time_precise() > s._poll_deadline then
    return fail("generation timed out — please try again")
  end
  if type(data.progress_percent) == "number" then
    s.progress = math.max(s.progress, math.min(89, math.floor(data.progress_percent * 0.89)))
  end
  s._next_poll = reaper.time_precise() + POLL_INTERVAL
end

local function handle_poll(err, data)
  local s = gen.state
  s._poll_inflight = false
  if s.status ~= "polling" then return end -- a reset (logout) dropped this job; ignore the stale response
  if err then return fail(err) end
  if not data then return fail("empty poll response") end
  if is_v3_kind(s.kind) then return handle_v3_poll(data) end
  return handle_v2_poll(data)
end

local function begin_poll(job_id)
  local s = gen.state
  if not s.kind then return end -- state was reset (logout) mid-flight; never poll a nil model
  s._poll_deadline = reaper.time_precise() + POLL_TIMEOUT_SEC
  s.job_id = job_id
  s.status = "polling"
  s.progress = math.max(s.progress, 2)
  s.message = "Generating…"
  s._next_poll = reaper.time_precise() + POLL_INTERVAL
  s._poll_inflight = false
end

-- ---- text pipeline ------------------------------------------------------
function gen.start_text(kind, params, captured_pos)
  reset(kind, kind == "music")
  local s = gen.state
  local job = epoch
  s.status = "submitting"; s.message = "Submitting…"
  s.captured_pos = captured_pos or 0
  s.num_samples = params.num_samples or 1
  s.place_name = s.is_music and "Mirelo Music" or "Mirelo SFX"
  s.label = truncate(params.prompt, 40)
  if s.label == "" then s.label = s.place_name end
  s.place_ctx = { mode = "cursor", pos = s.captured_pos }
  api.submit_job(kind, params, function(err, data)
    if epoch ~= job then return end
    if err then return fail(err) end
    local job_id = job_id_of(data)
    if not job_id then return fail("no job id returned") end
    begin_poll(job_id)
  end)
end

-- ---- video pipeline -----------------------------------------------------
function gen.start_video(kind, params, captured_pos, range)
  reset(kind, kind == "video_music")
  local s = gen.state
  local job = epoch
  s.captured_pos = captured_pos or range.start or 0
  s.num_samples = params.num_samples or 1
  s.place_name = s.is_music and "Mirelo Music" or "Mirelo SFX"
  s._name_from_output = true -- card label = the generated file's name (no source clip)
  s.place_ctx = { mode = "cursor", pos = s.captured_pos }
  s.status = "rendering"; s.message = "Rendering video…"; s.progress = 1
  local mp4 = render.tmp_mp4()
  s._render_file = mp4
  render.start(mp4, range.start, range.finish, function(rerr, path, duration)
    if epoch ~= job then return end
    if rerr then return fail(rerr) end
    s.status = "uploading"; s.message = "Uploading video…"; s.progress = 20
    api.create_asset("video/mp4", function(aerr, adata)
      if epoch ~= job then return end
      if aerr then return fail(aerr) end
      local ticket = asset_ticket(adata)
      if not ticket then return fail("asset reservation failed") end
      api.upload_asset(ticket, path, function(uerr)
        if epoch ~= job then return end
        if uerr then return fail("video upload failed: " .. uerr) end
        cleanup_temps()
        s.status = "submitting"; s.message = "Submitting…"; s.progress = 45
        local dms = params.duration_ms or math.floor((duration or range.len or 0) * 1000)
        api.submit_video(kind, ticket.id, { duration_ms = dms, num_samples = s.num_samples },
          function(serr, sdata)
            if epoch ~= job then return end
            if serr then return fail(serr) end
            local job_id = job_id_of(sdata)
            if not job_id then return fail("no job id returned") end
            begin_poll(job_id)
          end)
      end)
    end)
  end)
end

-- ---- extend pipeline ----------------------------------------------------

-- Video-conditioned extend: render the [prefix + extension] window to MP4,
-- upload the audio prefix AND the video, then submit extend-with-video.
local function start_extend_video(s, opts, clip, audio_file, prefix_dur, auto_trimmed)
  local job = epoch -- same epoch as the calling start_extend (no reset between)
  -- The job lives under the with_video endpoint, so poll_job must use that path.
  s.kind = "extend_video"
  s.status = "rendering"; s.message = "Rendering video…"; s.progress = 10
  -- prefix_dur is SOURCE-audio seconds; the render range is on the timeline, so
  -- convert by the take playrate (rate == 1 leaves the common case unchanged).
  -- The video window must align with the audio prefix; only offset when the
  -- prefix was auto-trimmed to the tail.
  local rate = (clip.take_playrate and clip.take_playrate ~= 0) and clip.take_playrate or 1
  local prefix_tl = prefix_dur / rate
  local head_offset = auto_trimmed and math.max(0, clip.item_len - prefix_tl) or 0
  local v_in = clip.item_pos + head_offset
  local v_out = v_in + prefix_tl + opts.extension_seconds
  local mp4 = render.tmp_mp4()
  s._render_file = mp4
  render.start(mp4, v_in, v_out, function(rerr, vpath)
    if epoch ~= job then return end
    if rerr then return fail(rerr) end
    s.status = "uploading"; s.message = "Uploading audio…"; s.progress = 30
    api.create_asset("audio/wav", function(ae, ad)
      if epoch ~= job then return end
      if ae then return fail(ae) end
      local audio_ticket = asset_ticket(ad)
      if not audio_ticket then return fail("asset reservation failed") end
      api.upload_asset(audio_ticket, audio_file, function(ue)
        if epoch ~= job then return end
        if ue then return fail("audio upload failed: " .. ue) end
        s.message = "Uploading video…"; s.progress = 45
        api.create_asset("video/mp4", function(ve, vd)
          if epoch ~= job then return end
          if ve then return fail(ve) end
          local video_ticket = asset_ticket(vd)
          if not video_ticket then return fail("asset reservation failed") end
          api.upload_asset(video_ticket, vpath, function(uve)
            if epoch ~= job then return end
            if uve then return fail("video upload failed: " .. uve) end
            cleanup_temps()
            s.status = "submitting"; s.message = "Submitting…"; s.progress = 55
            api.submit_extend_video(audio_ticket.id, video_ticket.id, {
              append_duration_ms = math.floor(opts.extension_seconds * 1000), num_samples = 1,
            }, function(se, sdata)
              if epoch ~= job then return end
              if se then return fail(se) end
              local job_id = job_id_of(sdata)
              if not job_id then return fail("no job id returned") end
              begin_poll(job_id)
            end)
          end)
        end)
      end)
    end)
  end)
end

-- opts = { extension_seconds, loop, use_video }; clip = R.get_selected_clip()
function gen.start_extend(opts, clip)
  reset("extend", false)
  local s = gen.state
  local job = epoch
  s.num_samples = 1
  s.active_clip = clip
  s.place_name = "Mirelo Extension"
  s.label = clip.basename or clip.name
  s.status = "uploading"; s.message = "Preparing clip…"; s.progress = 5

  local bytes = R.read_file(clip.source_file)
  if not bytes then return fail("couldn't read the clip's source file") end

  local rate = (clip.take_playrate and clip.take_playrate ~= 0) and clip.take_playrate or 1
  local in_point = clip.take_startoffs
  local out_point = in_point + clip.item_len * rate
  -- Auto-trim long prefixes so prefix + extension <= TOTAL_MAX (keep the tail).
  local target_max_prefix = math.max(0, TOTAL_MAX_SEC - opts.extension_seconds)
  local eff_in = in_point
  if (out_point - in_point) > target_max_prefix then eff_in = out_point - target_max_prefix end
  local auto_trimmed = eff_in ~= in_point

  local sliced, prefix_dur = wav.trim(bytes, eff_in, out_point)
  if not sliced then
    return fail("Couldn't slice this clip. Convert it to WAV in REAPER, then extend.")
  end

  -- Align the prefix's right edge with the original clip's right edge when the
  -- planner kept only the tail; otherwise anchor at the clip's left edge.
  -- prefix_dur is source seconds, so convert to timeline (/ rate) to match the
  -- clip's timeline item_len (and start_extend_video's prefix_tl); rate == 1 is
  -- the common case.
  local place_pos = clip.item_pos + (auto_trimmed and math.max(0, clip.item_len - prefix_dur / rate) or 0)
  s.place_ctx = { mode = "cursor", pos = place_pos }

  -- Highlight the appended (new) section in the result waveform.
  local total = prefix_dur + opts.extension_seconds
  s._hl = total > 0 and { from = prefix_dur / total, to = 1.0 } or nil

  local up = tmp_path("upload", "wav")
  if not R.write_file(up, sliced) then return fail("couldn't write temp upload file") end
  s._upload_file = up

  if opts.use_video then
    return start_extend_video(s, opts, clip, up, prefix_dur, auto_trimmed)
  end

  s.message = "Uploading…"; s.progress = 20
  api.create_asset("audio/wav", function(aerr, adata)
    if epoch ~= job then return end
    if aerr then return fail(aerr) end
    local ticket = asset_ticket(adata)
    if not ticket then return fail("asset reservation failed") end
    api.upload_asset(ticket, up, function(uerr)
      if epoch ~= job then return end
      cleanup_temps()
      if uerr then return fail("upload failed: " .. uerr) end
      s.status = "submitting"; s.message = "Submitting…"; s.progress = 45
      api.submit_extend(ticket.id, {
        append_duration_ms = math.floor(opts.extension_seconds * 1000),
        num_samples = 1, loop = opts.loop,
      }, function(serr, sdata)
        if epoch ~= job then return end
        if serr then return fail(serr) end
        local job_id = job_id_of(sdata)
        if not job_id then return fail("no job id returned") end
        begin_poll(job_id)
      end)
    end)
  end)
end

-- ---- inpaint pipeline ---------------------------------------------------
-- clip = R.get_selected_clip() with a valid time selection inside it.
function gen.start_inpaint(clip)
  reset("inpaint", false)
  local s = gen.state
  local job = epoch
  s.num_samples = 1
  s.active_clip = clip
  s.place_name = "Mirelo Inpaint"
  s.label = "Inpainted — " .. (clip.basename or clip.name)
  next_batch = next_batch + 1
  s._pair = next_batch -- groups Original + Inpainted into one section

  local rate = (clip.take_playrate and clip.take_playrate ~= 0) and clip.take_playrate or 1
  -- Source-relative gap (resolveInpaintSourceRegion): in-point + the timeline
  -- delta scaled by the take playrate (consistent with start_extend's
  -- item_len * rate; rate == 1 leaves the common case unchanged).
  local seg_start = clip.take_startoffs + (clip.ts_start - clip.item_pos) * rate
  local seg_end = seg_start + (clip.ts_end - clip.ts_start) * rate
  local seg_start_ms = math.max(0, math.floor(seg_start * 1000 + 0.5))
  local seg_end_ms = math.max(0, math.floor(seg_end * 1000 + 0.5))

  local clip_in = clip.take_startoffs
  local clip_out = clip_in + clip.item_len * rate
  s.place_ctx = { mode = "inpaint", pos = clip.item_pos, clip_in = clip_in, clip_out = clip_out }

  -- Highlight the regenerated window; offer the original clip as a "before" card.
  local dur = clip.source_length > 0 and clip.source_length or clip_out
  s._hl = dur > 0 and { from = math.max(0, seg_start / dur), to = math.min(1, seg_end / dur) } or nil
  s._original = { path = clip.source_file, name = "Original — " .. (clip.basename or clip.name) }

  s.status = "uploading"; s.message = "Uploading clip…"; s.progress = 15
  local content_type = audio_content_type(clip.source_ext)
  -- Upload the whole clip; the backend windows the segment server-side.
  api.create_asset(content_type, function(aerr, adata)
    if epoch ~= job then return end
    if aerr then return fail(aerr) end
    local ticket = asset_ticket(adata)
    if not ticket then return fail("asset reservation failed") end
    api.upload_asset(ticket, clip.source_file, function(uerr)
      if epoch ~= job then return end
      if uerr then return fail("upload failed: " .. uerr) end
      s.status = "submitting"; s.message = "Submitting…"; s.progress = 45
      api.submit_inpaint(ticket.id, {
        segment_start_ms = seg_start_ms, segment_end_ms = seg_end_ms, num_samples = 1,
      }, function(serr, sdata)
        if epoch ~= job then return end
        if serr then return fail(serr) end
        local job_id = job_id_of(sdata)
        if not job_id then return fail("no job id returned") end
        begin_poll(job_id)
      end)
    end)
  end)
end

-- Place a result on a track. Inpaint trims the result WAV to the clip footprint
-- first; others place as downloaded. Returns true on success — the caller shows
-- a "couldn't place" toast on false.
function gen.place(item)
  local ctx = item.place or { mode = "cursor", pos = 0 }
  local clip_name = item.place_name or item.name -- timeline clip name (e.g. "Mirelo SFX")
  local ok
  if ctx.mode == "inpaint" then
    -- The placed media item references the trimmed file on disk, so it must
    -- persist. Trim once and cache the path; subsequent ADD clicks on the same
    -- result reuse it instead of writing a fresh temp WAV each time. If the
    -- trim can't be produced, fail rather than placing the full untrimmed file
    -- (wrong audio at the inpaint window) without telling the user.
    if not item._placed_path then
      local bytes = R.read_file(item.path)
      local trimmed = bytes and wav.trim(bytes, ctx.clip_in, ctx.clip_out)
      if not trimmed then return false end
      local tmp = tmp_path("placed", "wav")
      if not R.write_file(tmp, trimmed) then return false end
      item._placed_path = tmp
    end
    ok = R.place_on_track(item._placed_path, ctx.pos, clip_name)
  else
    ok = R.place_on_track(item.path, ctx.pos, clip_name)
  end
  if ok then item._placed = true end -- now referenced by a timeline item; don't GC its file
  return ok
end

-- Delete a dropped result's temp download. We only ever remove files we created
-- ourselves (never an `original` card, whose path is the user's own source clip)
-- and only when the result was never placed — a placed clip's file is referenced
-- by a timeline item, so deleting it would break the user's project.
discard_files = function(item)
  if item.original or item._placed then return end
  if item.path then os.remove(item.path) end
  if item._placed_path then os.remove(item._placed_path) end
end

-- Remove a result from the history (the × button), by id. If the item belongs
-- to a group (the inpaint Original+Inpainted pair), the whole group is removed —
-- you can't delete just one half.
function gen.remove(id)
  local pair
  for _, r in ipairs(gen.history) do
    if r.id == id then pair = r.pair; break end
  end
  local kept = {}
  for _, r in ipairs(gen.history) do
    local drop = r.id == id or (pair ~= nil and r.pair == pair)
    if drop then discard_files(r) else kept[#kept + 1] = r end
  end
  gen.history = kept
end

-- Call once per frame, before reading gen.state in the UI.
function gen.update()
  net.update()
  render.update()
  local s = gen.state
  if s.status == "polling" and not s._poll_inflight and reaper.time_precise() >= s._next_poll then
    s._poll_inflight = true
    api.poll_job(s.kind, s.job_id, handle_poll)
  end
end

return gen
