-- Thin wrappers over the REAPER host API: time selection (duration source),
-- placing generated audio on a track, opening the browser for device auth, and
-- optional SWS-backed preview.

local R = {}
local SEP = package.config:sub(1, 1)
local is_win = SEP == "\\"

-- The time selection drives generation duration, exactly like the Electron
-- build's I/O range. Returns start, finish, length (seconds).
function R.time_selection()
  local s, e = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
  return s, e, math.max(0, e - s)
end

-- Detection by source type or file extension, matching the agent's gate.
local VIDEO_EXTS = {
  mp4 = true, mov = true, avi = true, mkv = true, webm = true,
  m4v = true, mpg = true, mpeg = true, wmv = true, flv = true,
}

local function resolved_source(src)
  -- REAPER wraps trimmed/reversed media in a SECTION source whose own filename
  -- is empty; follow one level to the real source.
  if reaper.GetMediaSourceParent and (reaper.GetMediaSourceType(src, "") or ""):upper() == "SECTION" then
    local parent = reaper.GetMediaSourceParent(src)
    if parent then return parent end
  end
  return src
end

-- How many video items overlap [ts0, ts1]? Gates Video->SFX/Music: rendering a
-- range with no video gives the model nothing to see.
function R.count_video_items_in_range(ts0, ts1)
  if ts1 <= ts0 then return 0 end
  local proj, count = 0, 0
  local n = reaper.CountMediaItems(proj)
  for i = 0, n - 1 do
    local item = reaper.GetMediaItem(proj, i)
    local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    local len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
    if pos < ts1 and (pos + len) > ts0 then
      local take = reaper.GetActiveTake(item)
      if take then
        local src = resolved_source(reaper.GetMediaItemTake_Source(take))
        local fn = reaper.GetMediaSourceFileName(src, "") or ""
        local typ = (reaper.GetMediaSourceType(src, "") or ""):upper()
        local ext = fn:match("%.([^.\\/]+)$")
        if (ext and VIDEO_EXTS[ext:lower()]) or typ:find("VIDEO") then
          count = count + 1
        end
      end
    end
  end
  return count
end

-- Video-item intervals overlapping forward from window_start (for the extender's
-- "Use video" gate). Returns an array of { start, finish } in timeline seconds.
function R.get_video_intervals(window_start)
  local proj, out = 0, {}
  local n = reaper.CountMediaItems(proj)
  for i = 0, n - 1 do
    local item = reaper.GetMediaItem(proj, i)
    local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    local endp = pos + reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
    if endp > window_start then
      local take = reaper.GetActiveTake(item)
      if take then
        local src = resolved_source(reaper.GetMediaItemTake_Source(take))
        local fn = reaper.GetMediaSourceFileName(src, "") or ""
        local typ = (reaper.GetMediaSourceType(src, "") or ""):upper()
        local ext = fn:match("%.([^.\\/]+)$")
        if (ext and VIDEO_EXTS[ext:lower()]) or typ:find("VIDEO") then
          out[#out + 1] = { start = pos, finish = endp }
        end
      end
    end
  end
  return out
end

-- Seconds -> "m:ss.s" for range display.
function R.format_tc(sec)
  local s = math.max(0, sec or 0)
  local m = math.floor(s / 60)
  return string.format("%d:%05.2f", m, s - m * 60)
end

-- The selected audio item's source + geometry (extender/inpainter input),
-- ported from the agent's handle_getclip. Returns nil for no/non-audio/MIDI
-- selection. Follows the SECTION wrapper to the real source.
function R.get_selected_clip()
  local proj = 0
  local item = reaper.GetSelectedMediaItem(proj, 0)
  if not item then return nil end
  local take = reaper.GetActiveTake(item)
  if not take or reaper.TakeIsMIDI(take) then return nil end
  local src = resolved_source(reaper.GetMediaItemTake_Source(take))
  if not src then return nil end
  local fn = reaper.GetMediaSourceFileName(src, "") or ""
  local typ = (reaper.GetMediaSourceType(src, "") or ""):upper()
  local ext = fn:match("%.([^.\\/]+)$")
  if (ext and VIDEO_EXTS[ext:lower()]) or typ:find("VIDEO") then return nil end -- audio only
  local ts0, ts1 = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
  local _, takename = reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false)
  local base = fn:match("[^/\\]+$") or fn
  return {
    source_file = fn,
    source_ext = ext and ext:lower() or "",
    source_length = reaper.GetMediaSourceLength(src) or 0,
    channels = reaper.GetMediaSourceNumChannels(src) or 2,
    srate = reaper.GetMediaSourceSampleRate(src) or 0,
    item_pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION"),
    item_len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH"),
    item_track = reaper.GetMediaTrackInfo_Value(reaper.GetMediaItem_Track(item), "IP_TRACKNUMBER"),
    take_startoffs = reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS"),
    take_playrate = reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE"),
    ts_start = ts0,
    ts_end = ts1,
    name = (takename ~= "" and takename) or base,
    basename = base, -- the source file name, for result-card labels
    is_audio = true,
  }
end

function R.read_file(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local data = f:read("*a")
  f:close()
  return data
end

function R.write_file(path, data)
  local f = io.open(path, "wb")
  if not f then return false end
  f:write(data)
  f:close()
  return true
end

function R.open_url(url)
  -- The version-check response's updateUrl is server-supplied and ends up here,
  -- and on macOS/Linux the fallbacks embed it in an os.execute shell string.
  -- Only ever launch a well-formed https URL whose characters can't break out
  -- of (or inject into) that string — reject anything else outright.
  if type(url) ~= "string" or not url:match("^https://[%w%-%._~/%?#%[%]@:=&%%]+$") then
    return
  end
  if reaper.CF_ShellExecute then -- SWS: ShellExecute, no shell parsing — handles any valid URL
    reaper.CF_ShellExecute(url)
    return
  end
  if is_win then
    -- `start` routes through cmd.exe, which expands %VAR% even inside quotes, so
    -- a '%' in the URL (a percent-encoded nonce, or a hostile updateUrl like
    -- ".../%COMSPEC%/...") would be mangled or substituted. Without SWS we can't
    -- ShellExecute, so skip rather than open a corrupted URL.
    if url:find("%", 1, true) then return end
    os.execute('start "" "' .. url .. '"')
  elseif reaper.GetOS():match("^OSX") or reaper.GetOS():match("^macOS") then
    os.execute('open "' .. url .. '"')
  else
    os.execute('xdg-open "' .. url .. '"')
  end
end

-- Programmatic sources don't auto-build waveform peaks (the GUI import path
-- does; scripting doesn't), so a placed item would play but show no waveform.
-- We place only short generated clips (≤ ~60s), so each run() pass chews through
-- the file in a handful of iterations and completes in well under a frame. The
-- guard is a runaway backstop, not the expected exit — if a future caller ever
-- places a long file, it caps the worst-case main-thread stall instead of
-- spinning indefinitely (peaks just finish later when REAPER rebuilds them).
local BUILD_PEAKS_MAX_PASSES = 20000
local function build_peaks(src)
  if not reaper.PCM_Source_BuildPeaks then return end
  reaper.PCM_Source_BuildPeaks(src, 0)
  local guard = 0
  while reaper.PCM_Source_BuildPeaks(src, 1) ~= 0 and guard < BUILD_PEAKS_MAX_PASSES do
    guard = guard + 1
  end
  reaper.PCM_Source_BuildPeaks(src, 2)
end

-- True when no item on `track` overlaps [pos, endp].
local function track_free_in_range(track, pos, endp)
  local cnt = reaper.CountTrackMediaItems(track)
  for j = 0, cnt - 1 do
    local it = reaper.GetTrackMediaItem(track, j)
    local ip = reaper.GetMediaItemInfo_Value(it, "D_POSITION")
    local il = reaper.GetMediaItemInfo_Value(it, "D_LENGTH")
    if ip < endp and (ip + il) > pos then return false end
  end
  return true
end

-- Place an audio file at `pos`. Reuses the first existing track that is FREE
-- across [pos, pos+len] (matching the DaVinci/Premiere behaviour); only creates
-- a new track when none is free. Builds peaks so the waveform shows.
-- Returns true on success.
function R.place_on_track(filepath, pos, name)
  if not filepath then return false end
  local proj = 0
  pos = pos or 0
  reaper.PreventUIRefresh(1)
  reaper.Undo_BeginBlock()
  local orphan_src -- a created source not yet owned by a take; freed on error below
  local ok, placed = pcall(function()
    local src = reaper.PCM_Source_CreateFromFile(filepath)
    if not src then return false end
    orphan_src = src
    local srclen = reaper.GetMediaSourceLength(src) or 0
    local endp = pos + srclen

    -- Reuse the first track free across the placement range; else a new one.
    local track
    local n = reaper.CountTracks(proj)
    for i = 0, n - 1 do
      local t = reaper.GetTrack(proj, i)
      if track_free_in_range(t, pos, endp) then track = t; break end
    end
    if not track then
      local idx = reaper.CountTracks(proj)
      reaper.InsertTrackAtIndex(idx, true)
      track = reaper.GetTrack(proj, idx)
      if name then reaper.GetSetMediaTrackInfo_String(track, "P_NAME", name, true) end
    end

    local item = reaper.AddMediaItemToTrack(track)
    local take = reaper.AddTakeToMediaItem(item)
    reaper.SetMediaItemTake_Source(take, src)
    orphan_src = nil -- the take owns the source now
    build_peaks(src)
    reaper.SetMediaItemPosition(item, pos, false)
    reaper.SetMediaItemLength(item, srclen, false)
    if name then reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", name, true) end
    reaper.UpdateItemInProject(item)
    return true
  end)
  -- If item/take creation threw before the source was attached, free it.
  if orphan_src and reaper.PCM_Source_Destroy then reaper.PCM_Source_Destroy(orphan_src) end
  reaper.Undo_EndBlock("Mirelo: add " .. (name or "audio"), -1)
  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  return ok and placed == true
end

-- Optional preview via SWS CF_Preview_* (no-op if SWS is absent).
local active_preview = nil
function R.preview(filepath)
  if not reaper.CF_CreatePreview then return false end
  R.stop_preview()
  local src = reaper.PCM_Source_CreateFromFile(filepath)
  if not src then return false end
  local pv = reaper.CF_CreatePreview(src)
  if not pv then
    if reaper.PCM_Source_Destroy then reaper.PCM_Source_Destroy(src) end
    return false
  end
  reaper.CF_Preview_Play(pv)
  active_preview = pv
  return true
end

function R.stop_preview()
  if active_preview and reaper.CF_Preview_Stop then
    reaper.CF_Preview_Stop(active_preview)
  end
  active_preview = nil
end

return R
