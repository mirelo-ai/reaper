-- User-facing error classification, ported from @studio/shared/plugin-errors.ts
-- (the V2 code catalog + HTTP-status fallbacks). Maps an API failure
-- (status + optional error.code + message) to { category, message, code } so
-- every catch site shows the same actionable copy as the other plugins.

local errors = {}

errors.CREDIT_MSG =
  "Your Mirelo credits or quota appear to be exhausted. Please check your Mirelo account billing/credits and try again."

-- Backend v2 error.code -> copy (apps/backend/convex/api/errors.ts is the source).
local V2 = {
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
  invalid_request = { m = "The request was rejected. Double-check the selection and try again.", c = "validation" },
  server_error = { m = "Mirelo is having trouble right now. Wait a moment and try again.", c = "server" },
}

local function http_view(status)
  if status == 401 then
    return { c = "auth", code = "auth_invalid", m = "Your Mirelo connection has expired. Reconnect your account." }
  elseif status == 402 or status == 429 then
    return { c = "credits", code = status == 429 and "rate_limited" or "insufficient_credits", m = errors.CREDIT_MSG }
  elseif status == 403 then
    return { c = "auth", code = "forbidden", m = "Your account doesn't have access to this feature." }
  elseif status == 404 then
    return { c = "asset", code = "not_found", m = "Mirelo couldn't find that resource. It may have expired — re-import the clip and try again." }
  elseif status == 408 or status == 504 then
    return { c = "network", code = "timeout", m = "The request timed out. Check your connection and try again." }
  elseif status == 422 or status == 400 then
    return { c = "validation", code = "invalid_request", m = "The request was rejected. Double-check the selection and try again." }
  elseif status >= 500 and status <= 599 then
    return { c = "server", code = "server_error", m = "Mirelo is having trouble right now. Wait a moment and try again." }
  end
  return nil
end

-- Returns { category, message, code }.
function errors.classify(status, code, message)
  if status == nil or status == 0 then
    return {
      category = "network", code = "network",
      message = "Mirelo is unreachable. Check your internet connection and try again.",
    }
  end
  if code and V2[code] then
    local e = V2[code]
    return { category = e.c, message = e.m, code = code }
  end
  local v = http_view(status)
  if v then return { category = v.c, message = v.m, code = v.code } end
  -- Authored short server messages pass through; long / multiline ones don't.
  if message and #message > 0 and #message <= 200 and not message:find("\n") then
    return { category = "server", message = message, code = "error" }
  end
  return { category = "unknown", message = "Something went wrong. Please try again.", code = "unknown" }
end

return errors
