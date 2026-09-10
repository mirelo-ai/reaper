-- User-facing error classification, ported from @studio/shared/plugin-errors.ts
-- (the error-code catalog + HTTP-status fallbacks). Maps an API failure
-- (status + optional error.code + message + param) to
-- { category, message, code, param } so every catch site shows the same
-- actionable copy as the other plugins.
--
-- One table serves both API versions: v3 kept every v2 spelling it carried
-- across, so only the codes below the divider are new.

local errors = {}

errors.CREDIT_MSG =
  "Your Mirelo credits or quota appear to be exhausted. Please check your Mirelo account billing/credits and try again."

-- Backend error.code -> copy (apps/backend/convex/api/v3/errors.ts is the
-- source; the codes above the divider are v2's too). `server = true` means the
-- backend's own message is preferred when it sent one: those failures are
-- described by a bound or a count only the server knows, so restating them here
-- would hardcode a limit that can move.
local CODES = {
  insufficient_credits = { m = errors.CREDIT_MSG, c = "credits" },
  no_active_subscription = { m = errors.CREDIT_MSG, c = "credits" },
  invalid_asset = { m = "The selected media is no longer available on Mirelo. Re-import the clip and try again.", c = "asset" },
  video_url_unreachable = { m = "Couldn't reach the video source. Re-import the clip and try again.", c = "asset" },
  audio_url_unreachable = { m = "Couldn't reach the audio source. Re-import the clip and try again.", c = "asset" },
  video_format_unsupported = { m = "That video format isn't supported. Try exporting as MP4 and re-import.", c = "asset" },
  audio_format_unsupported = { m = "That audio format isn't supported. Try exporting as WAV and re-import.", c = "asset" },
  video_too_short = { m = "The selected range is too short. Pick a longer region (at least one second).", c = "validation" },
  audio_too_short = { m = "The selected audio range is too short. Pick a longer region (at least one second).", c = "validation" },
  audio_too_long = { m = "The selected audio range is too long. Trim it to under ten minutes and try again.", c = "validation" },
  invalid_request = { m = "The request was rejected. Double-check the selection and try again.", c = "validation", server = true },
  server_error = { m = "Mirelo is having trouble right now. Wait a moment and try again.", c = "server" },
  -- Both are reported inside a 200 poll as well as as a status, so they need
  -- copy of their own rather than the 502 / 504 fallback.
  generation_failed = { m = "The generation failed. Try again, or adjust the prompt and selection.", c = "server" },
  generation_timeout = { m = "The generation took too long and was stopped. Try a shorter selection.", c = "server" },

  -- v3 only.
  --
  -- The concurrency ceiling is the one that most needs its own copy: it answers
  -- 429, so without it a caller with jobs already running is told their credits
  -- ran out.
  concurrency_limit_reached = { m = "You already have several generations running. Wait for one to finish and try again.", c = "concurrency", server = true },
  rate_limited = { m = "Too many requests in a row. Wait a moment and try again.", c = "rate_limit" },
  upstream_rate_limited = { m = "Mirelo is busy right now. Wait a moment and try again.", c = "rate_limit" },
  -- The upload goes straight to storage and Mirelo is never told when it lands,
  -- so a submit can genuinely arrive first. Retryable.
  asset_not_ready = { m = "Mirelo is still receiving the clip. Wait a moment and try again.", c = "asset" },
  payload_too_large = { m = "That file is too large to upload. Trim the selection and try again.", c = "validation", server = true },
  moderation_blocked = { m = "That prompt was rejected. Rephrase it and try again.", c = "validation" },
  invalid_region = { m = "That time selection can't be regenerated. Move or resize it and try again.", c = "validation", server = true },
  capability_unsupported = { m = "That combination of options isn't supported.", c = "validation", server = true },
  invalid_audio = { m = "Mirelo couldn't read that audio. Convert the clip to WAV and try again.", c = "asset" },
  invalid_video = { m = "Mirelo couldn't read that video. Try exporting as MP4 and re-import.", c = "asset" },
  model_not_found = { m = "This Mirelo model is no longer available. Update the plugin.", c = "server" },
  not_found = { m = "Mirelo couldn't find that resource. It may have expired — re-import the clip and try again.", c = "asset" },
  -- The audio was generated and charged for but couldn't be read back, so a
  -- retry pays twice for nothing.
  result_unreadable = { m = "Mirelo couldn't read the generated audio back. Try a different selection.", c = "server" },
  temporarily_unavailable = { m = "Mirelo is briefly unavailable. Wait a moment and try again.", c = "server" },
}

local function http_view(status)
  if status == 401 then
    return { c = "auth", code = "auth_invalid", m = "Your Mirelo connection has expired. Reconnect your account." }
  elseif status == 402 then
    return { c = "credits", code = "insufficient_credits", m = errors.CREDIT_MSG }
  elseif status == 429 then
    -- Not a credit failure: v3 answers 429 for the request-rate limiter and for
    -- the in-flight ceiling, and v2 for the rate limiter alone. A coded response
    -- has already been matched above; this is the fallback for one without.
    return { c = "rate_limit", code = "rate_limited", m = CODES.rate_limited.m }
  elseif status == 403 then
    return { c = "auth", code = "forbidden", m = "Your account doesn't have access to this feature." }
  elseif status == 404 then
    return { c = "asset", code = "not_found", m = CODES.not_found.m }
  elseif status == 408 or status == 504 then
    return { c = "network", code = "timeout", m = "The request timed out. Check your connection and try again." }
  elseif status == 413 then
    return { c = "validation", code = "payload_too_large", m = CODES.payload_too_large.m }
  elseif status == 422 or status == 400 then
    return { c = "validation", code = "invalid_request", m = "The request was rejected. Double-check the selection and try again." }
  elseif status >= 500 and status <= 599 then
    return { c = "server", code = "server_error", m = "Mirelo is having trouble right now. Wait a moment and try again." }
  end
  return nil
end

-- Authored short messages are worth showing; long / multiline ones are not.
local function authored(message)
  return type(message) == "string" and #message > 0 and #message <= 200 and not message:find("\n")
end

-- v3 names the offending request field in `param`. Fold it into the copy so the
-- user can see which input to fix, unless the message already names it.
local function with_param(message, param)
  if type(param) ~= "string" or param == "" then return message end
  if message:find(param, 1, true) then return message end
  return message .. " (" .. param .. ")"
end

local function coded_view(code, message, param)
  local e = code and CODES[code] or nil
  if not e then return nil end
  local copy = (e.server and authored(message)) and message or e.m
  return { category = e.c, message = with_param(copy, param), code = code, param = param }
end

local function message_view(message, param)
  if not authored(message) then return nil end
  return { category = "server", message = with_param(message, param), code = "error", param = param }
end

-- Fresh tables, never a shared constant: a view is handed to call sites that
-- may annotate it.
local function unknown_view()
  return { category = "unknown", message = "Something went wrong. Please try again.", code = "unknown" }
end

-- Returns { category, message, code, param }.
function errors.classify(status, code, message, param)
  if status == nil or status == 0 then
    return {
      category = "network", code = "network",
      message = "Mirelo is unreachable. Check your internet connection and try again.",
    }
  end
  local view = coded_view(code, message, param)
  if view then return view end
  local http = http_view(status)
  if http then return { category = http.c, message = with_param(http.m, param), code = http.code, param = param } end
  return message_view(message, param) or unknown_view()
end

-- A failure reported inside a job body rather than as an HTTP status. Same
-- catalog, no status fallback: a v3 job's `errors` arrive inside a 200, so there
-- is no number to fall back on.
function errors.for_job(code, message)
  return coded_view(code, message) or message_view(message) or unknown_view()
end

return errors
