-- Minimal pure-Lua JSON encode/decode.
-- No external deps so the script stays a single ReaPack-installable unit.
-- Decoder is permissive enough for the Mirelo API responses; encoder emits
-- only what the API accepts (objects, arrays, strings, numbers, booleans, null).

local json = {}

-- A sentinel distinct from nil so decoded `null` survives table storage.
json.null = setmetatable({}, { __tostring = function() return "null" end })

local escape_map = {
  ['"'] = '\\"',
  ['\\'] = '\\\\',
  ['\b'] = '\\b',
  ['\f'] = '\\f',
  ['\n'] = '\\n',
  ['\r'] = '\\r',
  ['\t'] = '\\t',
}

local function escape_string(s)
  return '"' .. s:gsub('[%z\1-\31"\\]', function(c)
    return escape_map[c] or string.format('\\u%04x', c:byte())
  end) .. '"'
end

local function is_array(t)
  local n = 0
  for k in pairs(t) do
    if type(k) ~= "number" then return false end
    n = n + 1
  end
  return n == #t
end

local encode_value

local function encode_table(t, out)
  if t == json.null then
    out[#out + 1] = "null"
  elseif is_array(t) then
    out[#out + 1] = "["
    for i = 1, #t do
      if i > 1 then out[#out + 1] = "," end
      encode_value(t[i], out)
    end
    out[#out + 1] = "]"
  else
    out[#out + 1] = "{"
    local first = true
    for k, v in pairs(t) do
      if not first then out[#out + 1] = "," end
      first = false
      out[#out + 1] = escape_string(tostring(k))
      out[#out + 1] = ":"
      encode_value(v, out)
    end
    out[#out + 1] = "}"
  end
end

encode_value = function(v, out)
  local kind = type(v)
  if v == json.null or v == nil then
    out[#out + 1] = "null"
  elseif kind == "string" then
    out[#out + 1] = escape_string(v)
  elseif kind == "number" then
    -- JSON has no Inf/NaN; emit a finite number or null.
    if v ~= v or v == math.huge or v == -math.huge then
      out[#out + 1] = "null"
    elseif math.type and math.type(v) == "integer" then
      out[#out + 1] = string.format("%d", v)
    else
      out[#out + 1] = string.format("%.14g", v)
    end
  elseif kind == "boolean" then
    out[#out + 1] = v and "true" or "false"
  elseif kind == "table" then
    encode_table(v, out)
  else
    error("json: cannot encode value of type " .. kind)
  end
end

function json.encode(v)
  local out = {}
  encode_value(v, out)
  return table.concat(out)
end

-- ---------------------------------------------------------------------------
-- Decoder
-- ---------------------------------------------------------------------------

local function skip_ws(s, i)
  local _, j = s:find("^[ \t\r\n]*", i)
  return (j or i - 1) + 1
end

local decode_value

local function decode_error(s, i, msg)
  error(string.format("json: %s at position %d", msg, i))
end

local function decode_string(s, i)
  -- i points at the opening quote.
  local buf, j = {}, i + 1
  while true do
    local c = s:sub(j, j)
    if c == "" then decode_error(s, j, "unterminated string") end
    if c == '"' then
      return table.concat(buf), j + 1
    elseif c == "\\" then
      local e = s:sub(j + 1, j + 1)
      if e == "u" then
        local hex = s:sub(j + 2, j + 5)
        local code = tonumber(hex, 16)
        if not code then decode_error(s, j, "bad unicode escape") end
        -- Encode the code point as UTF-8 (BMP only; surrogate pairs are rare
        -- in this API and pass through as raw bytes).
        if code < 0x80 then
          buf[#buf + 1] = string.char(code)
        elseif code < 0x800 then
          buf[#buf + 1] = string.char(0xC0 + math.floor(code / 0x40), 0x80 + code % 0x40)
        else
          buf[#buf + 1] = string.char(
            0xE0 + math.floor(code / 0x1000),
            0x80 + math.floor(code / 0x40) % 0x40,
            0x80 + code % 0x40)
        end
        j = j + 6
      else
        local map = { ['"'] = '"', ['\\'] = '\\', ['/'] = '/', b = '\b', f = '\f', n = '\n', r = '\r', t = '\t' }
        local ch = map[e]
        if not ch then decode_error(s, j, "bad escape") end
        buf[#buf + 1] = ch
        j = j + 2
      end
    else
      buf[#buf + 1] = c
      j = j + 1
    end
  end
end

local function decode_number(s, i)
  local num_str = s:match("^%-?%d+%.?%d*[eE]?[%+%-]?%d*", i)
  -- The pattern can match a degenerate exponent ("1e", "1e+") that tonumber
  -- rejects; treat that as a decode error rather than storing a silent nil.
  local n = num_str and tonumber(num_str)
  if not n then decode_error(s, i, "invalid number") end
  return n, i + #num_str
end

local function decode_array(s, i)
  local arr, j = {}, skip_ws(s, i + 1)
  if s:sub(j, j) == "]" then return arr, j + 1 end
  while true do
    local v
    v, j = decode_value(s, j)
    arr[#arr + 1] = v
    j = skip_ws(s, j)
    local c = s:sub(j, j)
    if c == "]" then return arr, j + 1 end
    if c ~= "," then decode_error(s, j, "expected ',' or ']'") end
    j = skip_ws(s, j + 1)
  end
end

local function decode_object(s, i)
  local obj, j = {}, skip_ws(s, i + 1)
  if s:sub(j, j) == "}" then return obj, j + 1 end
  while true do
    if s:sub(j, j) ~= '"' then decode_error(s, j, "expected object key") end
    local key
    key, j = decode_string(s, j)
    j = skip_ws(s, j)
    if s:sub(j, j) ~= ":" then decode_error(s, j, "expected ':'") end
    local v
    v, j = decode_value(s, skip_ws(s, j + 1))
    obj[key] = v
    j = skip_ws(s, j)
    local c = s:sub(j, j)
    if c == "}" then return obj, j + 1 end
    if c ~= "," then decode_error(s, j, "expected ',' or '}'") end
    j = skip_ws(s, j + 1)
  end
end

decode_value = function(s, i)
  i = skip_ws(s, i)
  local c = s:sub(i, i)
  if c == "{" then return decode_object(s, i) end
  if c == "[" then return decode_array(s, i) end
  if c == '"' then return decode_string(s, i) end
  if c == "-" or c:match("%d") then return decode_number(s, i) end
  if s:sub(i, i + 3) == "true" then return true, i + 4 end
  if s:sub(i, i + 4) == "false" then return false, i + 5 end
  if s:sub(i, i + 3) == "null" then return json.null, i + 4 end
  decode_error(s, i, "unexpected character '" .. c .. "'")
end

-- Returns (value) on success, or (nil, errmsg) on failure — never throws.
function json.decode(s)
  if type(s) ~= "string" or s == "" then return nil, "empty input" end
  local ok, value = pcall(function()
    local v, i = decode_value(s, 1)
    i = skip_ws(s, i)
    if i <= #s then decode_error(s, i, "trailing garbage") end
    return v
  end)
  if not ok then return nil, value end
  return value
end

return json
