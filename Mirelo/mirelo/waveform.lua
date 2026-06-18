-- Waveform extraction + DrawList rendering, mirroring the React canvas version
-- (RMS bars, 80 max, min 2px height, green / amber-extension colours).
--
-- Real RMS is computed for 16-bit PCM WAV (the SFX result format). For other
-- containers (e.g. the MP3 music format) we fall back to a deterministic
-- stylised waveform — a known follow-up is to pull peaks from REAPER's
-- PCM_Source instead. Either way the proof stands: the bars are hand-drawn.

local theme = require("mirelo.theme")

local wf = {}

local MAX_BARS = 80

local function u16(s, p) return s:byte(p) + s:byte(p + 1) * 256 end
local function u32(s, p)
  return s:byte(p) + s:byte(p + 1) * 256 + s:byte(p + 2) * 65536 + s:byte(p + 3) * 16777216
end
local function s16(lo, hi)
  local v = lo + hi * 256
  if v >= 32768 then v = v - 65536 end
  return v
end

-- Returns an array of 0..1 RMS magnitudes (length up to MAX_BARS), or nil.
local function rms_from_wav(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local head = f:read(12)
  if not head or head:sub(1, 4) ~= "RIFF" or head:sub(9, 12) ~= "WAVE" then
    f:close(); return nil
  end

  local fmt_ok, channels, bits = false, 1, 16
  local data_offset, data_size
  -- Walk chunks until we have fmt + data.
  while true do
    local ch = f:read(8)
    if not ch or #ch < 8 then break end
    local id = ch:sub(1, 4)
    local sz = u32(ch, 5)
    if id == "fmt " then
      local fmt = f:read(sz)
      if not fmt or #fmt < 16 then break end
      local audio_format = u16(fmt, 1)
      channels = u16(fmt, 3)
      bits = u16(fmt, 15)
      -- channels > 0 guards the block_align = channels * 2 below against a
      -- malformed zero-channel header (division by zero would crash the loop).
      fmt_ok = audio_format == 1 and bits == 16 and channels >= 1
      if sz % 2 == 1 then f:read(1) end
    elseif id == "data" then
      data_offset = f:seek()
      data_size = sz
      break
    else
      f:seek("cur", sz + (sz % 2)) -- chunks are word-aligned
    end
  end

  if not (fmt_ok and data_offset and data_size and data_size > 0) then
    f:close(); return nil
  end

  local block_align = channels * 2 -- 16-bit
  local total_frames = math.floor(data_size / block_align)
  if total_frames < 1 then f:close(); return nil end

  local bars = math.min(MAX_BARS, math.max(20, total_frames))
  local frames_per_bar = total_frames / bars
  -- Sample up to this many frames per bucket (spread cost across long files).
  local sample_cap = 256

  local out, peak = {}, 0.0001
  for b = 0, bars - 1 do
    local start_frame = math.floor(b * frames_per_bar)
    local take = math.min(sample_cap, math.max(1, math.floor(frames_per_bar)))
    f:seek("set", data_offset + start_frame * block_align)
    local raw = f:read(take * block_align) or ""
    local sum, n = 0.0, 0
    local i = 1
    while i + 1 <= #raw do
      local v = s16(raw:byte(i), raw:byte(i + 1)) / 32768
      sum = sum + v * v
      n = n + 1
      i = i + block_align -- first channel only
    end
    local rms = n > 0 and math.sqrt(sum / n) or 0
    out[b + 1] = rms
    if rms > peak then peak = rms end
  end
  f:close()

  -- Normalise so the loudest bar is full height.
  for i = 1, #out do out[i] = out[i] / peak end
  return out
end

-- Deterministic stylised bars (used when we can't decode the file).
local function stylised(path)
  local seed = 0
  for i = 1, #path do seed = (seed * 31 + path:byte(i)) % 100000 end
  local bars = {}
  for i = 1, 56 do
    local a = math.sin((i / 56) * math.pi) * 0.6 + 0.25
    local jitter = (((seed + i * 97) % 37) / 37) * 0.3
    bars[i] = math.min(1, a + jitter)
  end
  return bars
end

-- Public: compute bars for a file, caching on the item table.
function wf.bars_for(path)
  local b = rms_from_wav(path)
  if b then return b, true end
  return stylised(path), false
end

-- Draw bars into the current window via DrawList.
-- ctx, ImGui: ReaImGui handles. x,y,w,h: rect. bars: 0..1 array.
-- hi: optional { from, to } fraction range drawn in the amber accent (the
--     extended / inpainted region), matching the other plugins.
-- cursor_frac: 0..1 playback position (or nil).
function wf.draw(ctx, ImGui, x, y, w, h, bars, hi, cursor_frac)
  local dl = ImGui.GetWindowDrawList(ctx)
  local n = #bars
  if n == 0 then return end
  local bar_w = w / n
  local gap = bar_w > 3 and 1 or 0
  local mid = y + h / 2
  local max_h = h * 0.85
  -- Faint amber band behind the highlighted region so it reads even on silence.
  if hi then
    ImGui.DrawList_AddRectFilled(dl, x + hi.from * w, y, x + hi.to * w, y + h, 0xFFB84D22)
  end
  for i = 1, n do
    local bx = x + (i - 1) * bar_w
    local bh = math.max(2, bars[i] * max_h)
    local frac = (i - 0.5) / n
    local col = (hi and frac >= hi.from and frac <= hi.to) and theme.col.wave_ext or theme.col.wave
    ImGui.DrawList_AddRectFilled(dl, bx, mid - bh / 2, bx + bar_w - gap, mid + bh / 2, col)
  end
  if cursor_frac then
    local cx = x + cursor_frac * w
    ImGui.DrawList_AddLine(dl, cx, y, cx, y + h, theme.col.cursor, 1)
  end
end

return wf
