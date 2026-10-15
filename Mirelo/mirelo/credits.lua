-- Host-independent credit readiness and recovery helpers.

local credits = {}

credits.ACTIONS = {
  enable_overage = {
    label = "Enable overage",
    path = "/settings/billing",
  },
  increase_overage_limit = {
    label = "Increase overage limit",
    path = "/settings/billing",
  },
  view_plans = {
    label = "View plans",
    path = "/plan",
  },
  contact_support = {
    label = "Contact support",
    path = "/support",
    site = true,
  },
}

local PROVISIONING_STATES = {
  loading = true,
  pending = true,
  ready = true,
  stalled = true,
}

local function trim_trailing_slashes(value)
  return value:gsub("/+$", "")
end

function credits.action_url(action, studio_base)
  local approved = credits.ACTIONS[action]
  if not approved then return nil end
  local base = trim_trailing_slashes(studio_base or "https://mirelo.ai/studio")
  if approved.site then base = base:gsub("/studio$", "") end
  return base .. approved.path
end

function credits.approved_recovery_url(action, candidate, studio_base)
  local approved = credits.action_url(action, studio_base)
  if not approved then return nil end
  if type(candidate) ~= "string" then return approved end
  if candidate == approved then return candidate end
  local suffix = candidate:sub(#approved + 1, #approved + 1)
  if candidate:sub(1, #approved) == approved and (suffix == "?" or suffix == "#") then
    return candidate
  end
  return approved
end

function credits.decision(snapshot, needed, now_ms, request_recovery)
  snapshot = snapshot or {}
  local state = snapshot.provisioning_state or "loading"
  if state == "pending" and type(snapshot.provisioning_deadline) == "number"
      and now_ms >= snapshot.provisioning_deadline then
    state = "stalled"
  end
  if state ~= "ready" then
    return {
      allowed = false,
      state = state,
      recovery_action = state == "stalled" and "contact_support" or nil,
    }
  end
  if request_recovery then
    local request_state = request_recovery.provisioning_state or state
    local action = request_state == "stalled" and "contact_support"
      or request_recovery.recovery_action
    local allowed = request_state == "ready" and action == nil
      and request_recovery.credit_shortfall == 0
    return {
      allowed = allowed,
      state = request_state,
      recovery_action = action,
      recovery_url = request_recovery.recovery_url,
      credits_required = request_recovery.credits_required,
      credits_available = request_recovery.credits_available,
    }
  end
  if snapshot.billing_mode == "unmetered" then
    return { allowed = true, state = state }
  end
  local capacity = snapshot.spend_capacity
  if type(capacity) == "number" and type(needed) == "number" and capacity >= needed then
    return { allowed = true, state = state }
  end
  return {
    allowed = false,
    state = state,
    recovery_action = snapshot.recovery_action,
    recovery_url = snapshot.recovery_url,
  }
end

function credits.recovery_from_preflight(data, studio_base)
  local nested = type(data) == "table" and data.credit_recovery or nil
  local recovery = type(nested) == "table" and nested or data
  local action = type(recovery) == "table" and recovery.recovery_action or nil
  if type(recovery) ~= "table"
      or type(recovery.credits_required) ~= "number"
      or type(recovery.credits_available) ~= "number"
      or type(recovery.credit_shortfall) ~= "number"
      or (type(action) == "string" and not credits.ACTIONS[action]) then
    return nil
  end
  local state = recovery.provisioning_state
  if type(state) ~= "string" or not PROVISIONING_STATES[state] then state = "ready" end
  return {
    credits_required = recovery.credits_required,
    credits_available = recovery.credits_available,
    credit_shortfall = recovery.credit_shortfall,
    provisioning_state = state,
    recovery_action = type(action) == "string" and action or nil,
    recovery_url = type(action) == "string"
      and credits.approved_recovery_url(action, recovery.recovery_url, studio_base) or nil,
  }
end

function credits.recovery_from_error(data, studio_base)
  local err = type(data) == "table" and data.error or nil
  if type(err) ~= "table" then return nil end
  local recovery = type(err.credit_recovery) == "table" and err.credit_recovery or err
  if type(recovery.credits_required) ~= "number"
      or type(recovery.credits_available) ~= "number"
      or not credits.ACTIONS[recovery.recovery_action] then
    return nil
  end
  local state = recovery.provisioning_state
  if type(state) ~= "string" or not PROVISIONING_STATES[state] then state = "ready" end
  return {
    credits_required = recovery.credits_required,
    credits_available = recovery.credits_available,
    provisioning_state = state,
    recovery_action = recovery.recovery_action,
    recovery_url = credits.approved_recovery_url(
      recovery.recovery_action, recovery.recovery_url, studio_base),
  }
end

-- The whole milliseconds a text, video or extend request sends for a length.
-- Submit and quote both read it here, so the quote prices what the server bills.
function credits.request_ms(duration_sec)
  return math.floor(duration_sec * 1000)
end

-- Source-relative inpaint gap for a clip's time selection, in seconds: the take's
-- in-point plus the timeline delta scaled by the take playrate, as
-- resolveInpaintSourceRegion places it.
function credits.inpaint_segment(clip)
  local rate = (clip.take_playrate and clip.take_playrate ~= 0) and clip.take_playrate or 1
  local seg_start = clip.take_startoffs + (clip.ts_start - clip.item_pos) * rate
  return seg_start, seg_start + (clip.ts_end - clip.ts_start) * rate
end

-- The region an inpaint request sends, each end rounded to whole milliseconds on
-- its own. The server bills the width between them, which can be a millisecond
-- off the rounded gap.
function credits.region_ms(start_sec, end_sec)
  return math.max(0, math.floor(start_sec * 1000 + 0.5)),
    math.max(0, math.floor(end_sec * 1000 + 0.5))
end

-- What the server will charge for a request of this many whole milliseconds at
-- `rate` credits per second, shown until preflight answers. The rate is the one
-- the request's model publishes, so the estimate follows the model.
--
-- ceil(ms * samples * rate / 1000) in integers. Multiplying float seconds
-- instead lets binary rounding push a whole number past itself
-- (0.1 * 3 * 10 is 3.0000000000000004) and quote a credit the server does not
-- charge. A fractional rate has no exact integer form, so it rounds up in floats.
function credits.quote_ms(duration_ms, samples, rate)
  local whole = math.tointeger(rate)
  if whole then return (duration_ms * (samples or 1) * whole + 999) // 1000 end
  return math.ceil(duration_ms * (samples or 1) * rate / 1000)
end

return credits
