-- WAV read/slice helpers, ported from @studio/shared/audio-wav.ts. Operate on
-- Lua binary strings. Used to slice the extender prefix and trim the inpaint
-- result to the clip footprint — lossless, format-preserving (the fmt chunk is
-- copied verbatim). WAV-only; callers fall back / bail for other containers.

local wav = {}

local function u16le(s, p) return s:byte(p) + s:byte(p + 1) * 256 end
local function u32le(s, p)
  return s:byte(p) + s:byte(p + 1) * 256 + s:byte(p + 2) * 65536 + s:byte(p + 3) * 16777216
end
local function p32le(n)
  n = math.floor(n)
  return string.char(n & 0xFF, (n >> 8) & 0xFF, (n >> 16) & 0xFF, (n >> 24) & 0xFF)
end

-- Locate fmt + data chunks. Returns a layout table or nil.
local function locate(s)
  if #s < 44 then return nil end
  if s:sub(1, 4) ~= "RIFF" or s:sub(9, 12) ~= "WAVE" then return nil end
  local fmt_payload, fmt_size, audio_format, byte_rate, block_align
  local data_payload, data_size
  local o = 13 -- 1-based, first chunk after "RIFF"<size>"WAVE"
  while o + 7 <= #s do
    local id = s:sub(o, o + 3)
    local size = u32le(s, o + 4)
    local payload = o + 8
    if id == "fmt " and payload + 13 <= #s then
      fmt_payload = payload
      fmt_size = size
      audio_format = u16le(s, payload)
      byte_rate = u32le(s, payload + 8)
      block_align = u16le(s, payload + 12)
    elseif id == "data" then
      data_payload = payload
      data_size = size
      break
    end
    o = payload + size + (size % 2)
  end
  if not (fmt_payload and data_payload) then return nil end
  -- Lossless byte-slicing is only valid for uncompressed PCM (audio_format 1),
  -- where byte_rate/block_align map linearly to sample frames. For a compressed
  -- WAV (e.g. ADPCM) those fields mean something else and slicing would yield
  -- garbage; bail so the caller falls back / warns instead of uploading noise.
  if audio_format ~= 1 then return nil end
  if not (byte_rate and byte_rate > 0 and block_align and block_align > 0) then return nil end
  -- Clamp the declared data size to what's actually present (truncated files).
  data_size = math.min(data_size, #s - data_payload + 1)
  return {
    fmt_payload = fmt_payload, fmt_size = fmt_size,
    byte_rate = byte_rate, block_align = block_align,
    data_payload = data_payload, data_size = data_size,
  }
end

-- Duration in seconds, or nil if not a parseable WAV.
function wav.duration(s)
  local L = locate(s)
  if not L or L.data_size <= 0 then return nil end
  return L.data_size / L.byte_rate
end

-- Slice [startSec, endSec] losslessly into a fresh self-contained WAV string.
-- Returns (bytes, durationSec) or nil if not parseable / empty range.
function wav.trim(s, start_sec, end_sec)
  local L = locate(s)
  if not L then return nil end
  local cs = math.max(0, start_sec)
  local ce = math.max(cs, end_sec)
  local function align_down(v) return v - (v % L.block_align) end
  local start_byte = math.min(L.data_size, align_down(math.floor(cs * L.byte_rate)))
  local end_byte = math.min(L.data_size, align_down(math.floor(ce * L.byte_rate)))
  local new_data = end_byte - start_byte
  if new_data <= 0 then return nil end

  local fmt_padded = L.fmt_size + (L.fmt_size % 2)
  local riff_payload = 4 + 8 + fmt_padded + 8 + new_data
  local out = {
    "RIFF", p32le(riff_payload), "WAVE",
    "fmt ", p32le(L.fmt_size), s:sub(L.fmt_payload, L.fmt_payload + fmt_padded - 1),
    "data", p32le(new_data),
    s:sub(L.data_payload + start_byte, L.data_payload + end_byte - 1),
  }
  return table.concat(out), new_data / L.byte_rate
end

return wav
