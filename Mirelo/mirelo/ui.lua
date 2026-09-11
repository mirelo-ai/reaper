-- The ReaImGui surface. Recreates the DaVinci/Premiere plugin's look and flow:
-- header + branding, device-auth screen, and the generation screen with
-- segmented mode tabs, prompt input, progress, and result cards with a
-- hand-drawn waveform + Add-to-track.

local theme   = require("mirelo.theme")
local store   = require("mirelo.store")
local api     = require("mirelo.api")
local gen     = require("mirelo.generation")
local net     = require("mirelo.net")
local R       = require("mirelo.reaper_io")
local wf       = require("mirelo.waveform")
local vc      = require("mirelo.video_coverage")

local ui = {}

local ImGui, ctx, logo

-- ---- view model ----------------------------------------------------------
local M = {
  route = "loading", -- loading | auth | main
  -- auth
  nonce = nil, connecting = false, auth_msg = "", auth_next = 0, auth_inflight = false,
  -- account
  capacity = nil, email = nil, me_inflight = false,
  -- model registry (GET /v3/models), fetched once per session at sign-in.
  -- Same nil-means-unknown convention as M.capacity: M.limits is set only once
  -- a fetch has actually landed.
  limits = nil,
  models_status = "idle", -- idle | loading | ready | error
  models_inflight = false,
  models_attempt = 0,
  models_deadline = 0,  -- time_precise() the whole budget expires at
  models_retry_at = 0,  -- time_precise() the next attempt may start
  models_epoch = 0,     -- bumped to disown a reply from an abandoned fetch
  -- version gate
  version_blocked = nil,   -- { message, url } when this build is blocked
  version_notice = nil,    -- { message, url } for a dismissible "update available"
  version_next_check = 0,  -- time_precise() of the next check (0 = check now)
  version_dismissed = nil, -- message the user dismissed (don't re-show it)
  -- form
  mode = "sfx",      -- sfx | music | extend | inpaint
  source = "text",   -- text | video
  prompt = "",
  num_samples = 1,
  -- extender
  extension = 5.0,
  loop = false,
  ext_use_video = false,
  -- feedback modal
  feedback_text = "",
  feedback_status = "idle", -- idle | sending | sent | error
  feedback_error = "",
  -- toast
  toast = nil, toast_until = 0, toast_kind = "info",
  -- playback
  play_idx = nil, play_started = 0, play_dur = 0,
  -- caches
  wave = {}, -- path -> {bars, real}
}

-- Duration bounds (seconds) for the two music endpoints, and how many samples
-- they take. There is no music family in v3, so `GET /v3/models` says nothing
-- about music and these stay compiled in; the sfx and video-to-sfx bounds that
-- used to sit beside them now come off the registry.
local MUSIC_LIMITS = {
  music       = { min = 3.0, max = 120.0, samples = 4 },
  video_music = { min = 3.0, max = 120.0, samples = 4 },
}

-- Floors this plugin deliberately holds ABOVE what the API accepts.
--
-- The registry can only publish capability. These two are product choices, and
-- @studio/shared/audio-constants is where they are argued: SFX_TEXT_DURATION_
-- SECONDS and SFX_EXTEND_LIMITS both sit above their API counterparts so
-- "interactive surfaces keep enough generated material for a smooth
-- transition". The effective bound is whichever of the two is stricter, folded
-- in where the registry lands.
local PRODUCT_FLOORS = { sfx = 1.0, extend_loop = 2.0 }

-- Extender bounds the plugin holds itself, because the registry has no field
-- for either. PREFIX_MIN is a property of the caller's own clip — the model
-- needs some audio ahead of the join to condition on — and EXT_TOTAL_MAX
-- bounds prefix + extension together, a total v3 publishes no key for. The
-- new-audio bounds beside them do come from `GET /v3/models`.
local PREFIX_MIN, EXT_TOTAL_MAX = 3.0, 60.0

-- Map (mode, source) -> endpoint kind used by generation/api.
local function endpoint_kind()
  if M.source == "video" then
    return M.mode == "music" and "video_music" or "video_sfx"
  end
  return M.mode
end

-- Duration bounds for one endpoint kind. nil while the registry hasn't
-- answered, which only happens on a kind the registry covers.
local function dur_limits(kind)
  return MUSIC_LIMITS[kind] or (M.limits and M.limits.duration[kind])
end

-- The `num_variants` ceiling for one endpoint kind.
local function samples_max(kind)
  local music = MUSIC_LIMITS[kind]
  if music then return music.samples end
  return (M.limits and M.limits.samples[kind]) or 1
end

-- A bound as text. These come off the registry now, so a bound is no longer
-- guaranteed to be whole and "%.0f" would print 0.5s as "0s".
local function secs_text(n)
  if n == math.floor(n) then return string.format("%.0f", n) end
  return string.format("%.1f", n)
end

-- ---- small helpers --------------------------------------------------------

local function toast(msg, kind)
  M.toast = msg
  M.toast_kind = kind or "info"
  M.toast_until = reaper.time_precise() + 3.0
end

local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end
local function round1(n) return math.floor(n * 10 + 0.5) / 10 end

-- Thousands separators (e.g. 1435778 -> "1,435,778"), matching the other plugins.
local function commas(n)
  local s = string.format("%d", math.floor((n or 0) + 0.5))
  return (s:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", ""))
end

-- Credit cost: ceil(duration * samples * rate). All v1.6/v1.0 models bill at 10/s.
local CREDIT_RATE = 10
local function credits_for(dur, samples) return math.ceil(dur * (samples or 1) * CREDIT_RATE) end
-- spend_capacity is the answer to exactly this question: the ledger balance,
-- less credits already committed by jobs in flight, plus any enabled overage
-- headroom. Nil on an unmetered key, which is never refused.
local function enough_credits(needed)
  return M.capacity == nil or M.capacity >= needed
end

local function avail_w()
  local w = ImGui.GetContentRegionAvail(ctx)
  return w
end

-- A primary (sky) pill button spanning the full content width.
local function primary_button(label, enabled)
  local w = avail_w()
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_FrameRounding, theme.space.btn_h / 2)
  if enabled then
    ImGui.PushStyleColor(ctx, ImGui.Col_Button, theme.col.cta)
    ImGui.PushStyleColor(ctx, ImGui.Col_ButtonHovered, theme.col.cta_hover)
    ImGui.PushStyleColor(ctx, ImGui.Col_ButtonActive, theme.col.cta)
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, theme.col.cta_text)
  else
    ImGui.PushStyleColor(ctx, ImGui.Col_Button, theme.col.cta_disabled)
    ImGui.PushStyleColor(ctx, ImGui.Col_ButtonHovered, theme.col.cta_disabled)
    ImGui.PushStyleColor(ctx, ImGui.Col_ButtonActive, theme.col.cta_disabled)
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, theme.col.cta_disabled_text)
  end
  if not enabled then ImGui.BeginDisabled(ctx) end
  local clicked = ImGui.Button(ctx, label, w, theme.space.btn_h)
  if not enabled then ImGui.EndDisabled(ctx) end
  ImGui.PopStyleColor(ctx, 4)
  ImGui.PopStyleVar(ctx, 1)
  return enabled and clicked
end

-- A compact dark "card" button (ADD).
local function card_button(label, w)
  ImGui.PushStyleColor(ctx, ImGui.Col_Button, theme.col.card_btn)
  ImGui.PushStyleColor(ctx, ImGui.Col_ButtonHovered, theme.col.card_btn_hi)
  ImGui.PushStyleColor(ctx, ImGui.Col_ButtonActive, theme.col.card_btn)
  ImGui.PushStyleColor(ctx, ImGui.Col_Text, theme.col.text)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_FrameRounding, theme.space.radius_sm)
  -- height 0 → auto-size from FramePadding, so the label is vertically centred
  -- with margins on every side (no text glued to the bottom border).
  local clicked = ImGui.Button(ctx, label, w or 0, 0)
  ImGui.PopStyleVar(ctx, 1)
  ImGui.PopStyleColor(ctx, 4)
  return clicked
end

-- Visible checkbox: lighter box + border + a bright sky tick (the default
-- dark-on-dark box is nearly invisible until hovered).
local function checkbox(label, value)
  ImGui.PushStyleColor(ctx, ImGui.Col_FrameBg, theme.col.checkbox_bg)
  ImGui.PushStyleColor(ctx, ImGui.Col_FrameBgHovered, theme.col.checkbox_bg_hover)
  ImGui.PushStyleColor(ctx, ImGui.Col_FrameBgActive, theme.col.checkbox_bg_hover)
  ImGui.PushStyleColor(ctx, ImGui.Col_CheckMark, theme.col.check_mark)
  ImGui.PushStyleColor(ctx, ImGui.Col_Border, theme.col.checkbox_border)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_FrameBorderSize, 1)
  local changed, v = ImGui.Checkbox(ctx, label, value)
  ImGui.PopStyleVar(ctx, 1)
  ImGui.PopStyleColor(ctx, 5)
  return changed, v
end

-- Visible radio button (same styling as the checkbox). Returns true on click.
local function radio(label, active)
  ImGui.PushStyleColor(ctx, ImGui.Col_FrameBg, theme.col.checkbox_bg)
  ImGui.PushStyleColor(ctx, ImGui.Col_FrameBgHovered, theme.col.checkbox_bg_hover)
  ImGui.PushStyleColor(ctx, ImGui.Col_FrameBgActive, theme.col.checkbox_bg_hover)
  ImGui.PushStyleColor(ctx, ImGui.Col_CheckMark, theme.col.check_mark)
  ImGui.PushStyleColor(ctx, ImGui.Col_Border, theme.col.checkbox_border)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_FrameBorderSize, 1)
  local clicked = ImGui.RadioButton(ctx, label, active)
  ImGui.PopStyleVar(ctx, 1)
  ImGui.PopStyleColor(ctx, 5)
  return clicked
end

-- Small vector tool icons drawn into a ~16px box centred at (cx, cy), so the
-- tabs read like the icon+label tabs in the DaVinci / Premiere plugins.
local function draw_tab_icon(dl, kind, cx, cy, col)
  if kind == "sfx" then
    local xs, hs = { -6, -3, 0, 3, 6 }, { 5, 10, 14, 8, 6 }
    for i = 1, 5 do
      local x, hh = cx + xs[i], hs[i] / 2
      ImGui.DrawList_AddRectFilled(dl, x - 0.9, cy - hh, x + 0.9, cy + hh, col)
    end
  elseif kind == "music" then
    ImGui.DrawList_AddCircleFilled(dl, cx - 3, cy + 4, 2.6, col)
    ImGui.DrawList_AddLine(dl, cx - 0.6, cy + 4, cx - 0.6, cy - 6, col, 1.6)
    ImGui.DrawList_AddLine(dl, cx - 0.6, cy - 6, cx + 4, cy - 4, col, 1.6)
  elseif kind == "extend" then
    for _, ox in ipairs({ -2, 3 }) do
      ImGui.DrawList_AddLine(dl, cx + ox - 2, cy - 5, cx + ox + 2, cy, col, 1.6)
      ImGui.DrawList_AddLine(dl, cx + ox + 2, cy, cx + ox - 2, cy + 5, col, 1.6)
    end
  elseif kind == "inpaint" then
    ImGui.DrawList_AddRect(dl, cx - 7, cy - 5, cx + 7, cy + 5, col, 2, 0, 1.2)
    ImGui.DrawList_AddRectFilled(dl, cx - 2, cy - 5, cx + 2, cy + 5, col)
  end
end

-- Segmented pill toggle (mode tabs / source). items: {{id, label, icon?}}.
-- Drawn manually (InvisibleButton + DrawList) so we control the icon + label
-- layout and the active/hover fills. Returns the selected id.
local function segmented(id, items, current, height)
  height = height or 30
  local w = avail_w()
  local seg = w / #items
  local dl = ImGui.GetWindowDrawList(ctx)
  local sx, sy = ImGui.GetCursorScreenPos(ctx)
  ImGui.DrawList_AddRectFilled(dl, sx, sy, sx + w, sy + height, theme.col.tab_track, height / 2)

  local selected = current
  for i, it in ipairs(items) do
    local seg_x = sx + (i - 1) * seg
    ImGui.SetCursorScreenPos(ctx, seg_x, sy)
    if ImGui.InvisibleButton(ctx, "##" .. id .. i, seg, height) then selected = it.id end
    local active = it.id == current
    if active then
      ImGui.DrawList_AddRectFilled(dl, seg_x + 1, sy + 1, seg_x + seg - 1, sy + height - 1, theme.col.tab_active, (height - 2) / 2)
    elseif ImGui.IsItemHovered(ctx) then
      ImGui.DrawList_AddRectFilled(dl, seg_x + 1, sy + 1, seg_x + seg - 1, sy + height - 1, 0x4B556640, (height - 2) / 2)
    end
    local col = active and theme.col.text or theme.col.text_muted
    local img = it.icon and M.icons and M.icons[it.icon]
    local lw, lh = ImGui.CalcTextSize(ctx, it.label)
    local icon_w = it.icon and 16 or 0
    local gap = it.icon and 5 or 0
    local gx = seg_x + (seg - (icon_w + gap + lw)) / 2
    if img then
      -- alpha-only tint so the dim works no matter the icon's own colours
      local tint = active and 0xFFFFFFFF or 0xFFFFFFB0
      local iy = sy + height / 2 - 8
      ImGui.DrawList_AddImage(dl, img, gx, iy, gx + 16, iy + 16, 0, 0, 1, 1, tint)
    elseif it.icon then
      draw_tab_icon(dl, it.icon, gx + icon_w / 2, sy + height / 2, col)
    end
    ImGui.DrawList_AddText(dl, gx + icon_w + gap, sy + (height - lh) / 2, col, it.label)
  end
  ImGui.SetCursorScreenPos(ctx, sx, sy + height)
  return selected
end

-- Close (×) button drawn with DrawList lines — font-independent and clearly
-- visible (the small text "x" was getting clipped at the card's edge).
local function close_button(id, sz)
  local dl = ImGui.GetWindowDrawList(ctx)
  local x, y = ImGui.GetCursorScreenPos(ctx)
  local clicked = ImGui.InvisibleButton(ctx, "##" .. id, sz, sz)
  local hov = ImGui.IsItemHovered(ctx)
  if hov then ImGui.DrawList_AddRectFilled(dl, x, y, x + sz, y + sz, theme.col.card_btn_hi, 3) end
  local col = hov and theme.col.text or theme.col.text_muted
  local p = sz * 0.3
  ImGui.DrawList_AddLine(dl, x + p, y + p, x + sz - p, y + sz - p, col, 1.6)
  ImGui.DrawList_AddLine(dl, x + sz - p, y + p, x + p, y + sz - p, col, 1.6)
  return clicked
end

-- Circular play/pause button drawn with DrawList (default font lacks glyphs).
local function play_button(id, playing, sz)
  local dl = ImGui.GetWindowDrawList(ctx)
  local x, y = ImGui.GetCursorScreenPos(ctx)
  local clicked = ImGui.InvisibleButton(ctx, id, sz, sz)
  local hovered = ImGui.IsItemHovered(ctx)
  local cx, cy, r = x + sz / 2, y + sz / 2, sz / 2
  ImGui.DrawList_AddCircleFilled(dl, cx, cy, r, hovered and theme.col.card_btn_hi or theme.col.card_btn)
  local g = theme.col.play_glyph
  if playing then
    local bw = sz * 0.12
    ImGui.DrawList_AddRectFilled(dl, cx - bw * 1.6, cy - r * 0.4, cx - bw * 0.4, cy + r * 0.4, g)
    ImGui.DrawList_AddRectFilled(dl, cx + bw * 0.4, cy - r * 0.4, cx + bw * 1.6, cy + r * 0.4, g)
  else
    local t = r * 0.42
    ImGui.DrawList_AddTriangleFilled(dl, cx - t * 0.7, cy - t, cx - t * 0.7, cy + t, cx + t, cy, g)
  end
  return clicked
end

-- ---- auth + account network state ----------------------------------------

-- Every nullable field on /v3/me arrives as JSON null on an unmetered or
-- organization key, and null decodes to a truthy sentinel — so fold anything
-- that isn't the expected type back to nil, or the "unknown / unmetered"
-- branches stop being reachable and commas() is handed a table.
local function typed(value, kind)
  if type(value) == kind then return value end
  return nil
end

local function fetch_me()
  if M.me_inflight then return end
  M.me_inflight = true
  api.me(function(err, data, status)
    M.me_inflight = false
    if status == 401 or status == 403 then
      store.clear_api_key()
      M.route = "auth"
      return
    end
    if not err and data then
      -- spend_capacity, not credits_available: the balance reconciles against
      -- an invoice, the capacity is what the next request may actually spend,
      -- and this panel only ever asks the second question.
      M.capacity = typed(data.spend_capacity, "number")
      M.email = typed(data.email, "string")
    end
  end)
end

-- ---- model registry ------------------------------------------------------
-- The generation form's bounds all come from `GET /v3/models`, so this call
-- gates the form. There is deliberately no fallback to compiled numbers: a
-- stale bound silently refuses a request the API would have accepted, which is
-- worse than a visible error, so an unreachable API means no form at all.

local TUNING = api.MODELS_TUNING

local start_models_attempt -- forward declaration: the callback reschedules it

local function fetch_models()
  if M.models_status == "loading" or M.models_status == "ready" then return end
  M.models_epoch = M.models_epoch + 1
  M.models_status = "loading"
  M.models_attempt = 0
  M.models_deadline = reaper.time_precise() + TUNING.budget
  M.models_retry_at = 0
  start_models_attempt()
end

start_models_attempt = function()
  M.models_inflight = true
  M.models_attempt = M.models_attempt + 1
  local epoch = M.models_epoch
  -- The attempts and their backoffs are sized to fill the budget exactly, so
  -- the frame the tick costs between them pushes the last attempt's own cap
  -- past the deadline. Hand it what is actually left instead: the reply would
  -- be refused anyway, and this stops a detached curl waiting for it. The
  -- floor is unreachable — no caller starts an attempt with less than
  -- min_attempt left — and exists only because curl reads a max-time of 0 as
  -- no limit at all.
  local remaining = M.models_deadline - reaper.time_precise()
  local timeout = math.max(TUNING.min_attempt, math.min(TUNING.timeout, remaining))
  api.models(function(err, data, _status, category)
    -- The fetch this reply belongs to was abandoned (budget spent, or a logout
    -- tore the session down), so its state is gone and must not be revived.
    if epoch ~= M.models_epoch then return end
    M.models_inflight = false
    local limits = (not err) and api.model_limits(data, api.V3_MODEL) or nil
    if limits then
      -- Fold the bounds the plugin holds itself in here, once, so every read
      -- site downstream sees a single effective bound instead of re-deciding.
      limits.duration.sfx.min = math.max(limits.duration.sfx.min, PRODUCT_FLOORS.sfx)
      limits.extend.min_with_loop =
        math.max(limits.extend.min_with_loop, PRODUCT_FLOORS.extend_loop)
      -- The append ceiling is bounded by the plugin's own arithmetic as well:
      -- generation.lua trims the prefix to EXT_TOTAL_MAX less the extension, so
      -- an extension past EXT_TOTAL_MAX - PREFIX_MIN leaves too little audio
      -- ahead of the join for the model to condition on, and the request is
      -- refused after the upload. The published ceiling is exactly that today,
      -- and the whole point of reading it is that it need not stay that way.
      limits.extend.max = math.min(limits.extend.max, EXT_TOTAL_MAX - PREFIX_MIN)
      M.limits = limits
      M.models_status = "ready"
      return
    end
    -- A 200 that didn't carry the bounds is as unusable as no answer, and no
    -- retry fixes it, so it fails now rather than after the whole ladder.
    if not (err and api.models_retryable(category)) or M.models_attempt >= TUNING.attempts then
      M.models_status = "error"
      return
    end
    M.models_retry_at = reaper.time_precise() + TUNING.backoff
  end, timeout)
end

-- TUNING.budget is a deadline polled here rather than a timeout on a promise:
-- Lua has neither, and net.request is a detached curl this same tick watches
-- for a completion marker. It also has to bound the whole run independently of
-- curl's own per-attempt cap, because net gives a request a grace period over
-- that cap for the case where curl is missing and no marker ever arrives.
--
-- ui.draw drains net before calling this, so a reply that landed in the same
-- frame the deadline trips still counts.
local function update_models()
  if M.models_status ~= "loading" then return end
  local now = reaper.time_precise()
  if now >= M.models_deadline then
    M.models_epoch = M.models_epoch + 1 -- a late reply must not revive the form
    M.models_inflight = false
    M.models_status = "error"
    return
  end
  -- Only start an attempt the budget can still hold. A retry can come due with
  -- a sliver left, and one started there outlives the deadline without ever
  -- being able to answer inside it.
  if not M.models_inflight and now >= M.models_retry_at
    and M.models_deadline - now >= TUNING.min_attempt then
    start_models_attempt()
  end
end

-- Re-check every 24h while the plugin stays open (matches usePluginVersionCheck).
local VERSION_RECHECK = 24 * 60 * 60
local function check_version()
  api.check_version(function(err, data)
    if err or not data then return end -- soft-fail: a check error never blocks use
    if data.blocked then
      M.version_blocked = {
        message = data.message or "This version is no longer supported. Please update.",
        url = data.updateUrl,
      }
    else
      M.version_blocked = nil -- clear if the server un-blocked since the last check
      if data.message and data.message ~= "" and data.message ~= M.version_dismissed then
        M.version_notice = { message = data.message, url = data.updateUrl }
      else
        M.version_notice = nil -- server no longer advertises an update (or it was dismissed)
      end
    end
  end)
end

local function start_connect()
  if M.connecting then return end -- already handshaking; ignore a double-click
  M.connecting = true -- disable Connect now, before the async nonce returns
  M.auth_fails = 0
  M.auth_msg = "Creating connection…"
  api.create_nonce(function(err, data)
    if err or not data or not data.nonce then
      M.auth_msg = "Couldn't start: " .. (err or "no nonce")
      M.connecting = false
      return
    end
    M.nonce = data.nonce
    M.connecting = true
    M.auth_msg = "Waiting for approval in your browser…"
    M.auth_next = reaper.time_precise() + 2.0
    M.auth_inflight = false
    R.open_url(api.connect_url(data.nonce))
  end)
end

local function update_auth()
  if not M.connecting or M.auth_inflight then return end
  if reaper.time_precise() < M.auth_next then return end
  M.auth_inflight = true
  api.poll_nonce(M.nonce, function(err, data)
    M.auth_inflight = false
    M.auth_next = reaper.time_precise() + 2.0
    if err or not data then
      -- Keep polling (a transient blip self-recovers), but surface persistent
      -- failures so the user isn't stuck on "Waiting…" with no feedback.
      M.auth_fails = (M.auth_fails or 0) + 1
      if M.auth_fails >= 3 then
        M.auth_msg = "Trouble reaching Mirelo — retrying. Check your connection."
      end
      return
    end
    M.auth_fails = 0
    -- Require a real string key: JSON null decodes to the json.null sentinel
    -- (a truthy table), so a plain `and data.apiKey` would store a non-string.
    if data.status == "ready" and type(data.apiKey) == "string" and data.apiKey ~= "" then
      store.set_api_key(data.apiKey)
      M.connecting = false
      M.route = "main"
      M.capacity = nil
      fetch_me()
      fetch_models()
    elseif data.status == "expired" then
      M.connecting = false
      M.auth_msg = "Connection expired. Try again."
    else
      M.auth_msg = "Waiting for approval in your browser…" -- restore after a blip
    end
  end)
end

-- ---- screens --------------------------------------------------------------

local function draw_header()
  ImGui.PushFont(ctx, theme.fonts.base)
  if logo then
    local ok, iw, ih = pcall(function()
      if ImGui.Image_GetSize then return ImGui.Image_GetSize(logo) end
      return 96, 24
    end)
    local h = 22
    local w = (ok and ih and ih > 0) and (iw * (h / ih)) or 90
    ImGui.Image(ctx, logo, w, h)
  else
    ImGui.TextColored(ctx, theme.col.text, "Mirelo")
  end

  -- Right-aligned Feedback / Logout (only when connected).
  if M.route == "main" then
    -- Size each button to its label (+ frame padding) so text never clips.
    local fb_w = math.floor(ImGui.CalcTextSize(ctx, "Feedback") + 22)
    local lo_w = math.floor(ImGui.CalcTextSize(ctx, "Logout") + 22)
    ImGui.SameLine(ctx)
    ImGui.SetCursorPosX(ctx, ImGui.GetWindowWidth(ctx) - (fb_w + lo_w + 8) - theme.space.panel_pad)
    if card_button("Feedback", fb_w) then
      M.feedback_text = ""; M.feedback_status = "idle"; M.feedback_error = ""
      ImGui.OpenPopup(ctx, "Send feedback")
    end
    ImGui.SameLine(ctx, 0, 8)
    if card_button("Logout", lo_w) then
      ImGui.OpenPopup(ctx, "Disconnect")
    end
  end
  ImGui.PopFont(ctx)
  ImGui.Dummy(ctx, 0, 2)
  ImGui.Separator(ctx)
  ImGui.Dummy(ctx, 0, 4)
end

local function draw_auth()
  ImGui.PushFont(ctx, theme.fonts.base)
  ImGui.Dummy(ctx, 0, 8)
  ImGui.TextColored(ctx, theme.col.text, "Connect your Mirelo account")
  ImGui.PushFont(ctx, theme.fonts.sm)
  ImGui.PushStyleColor(ctx, ImGui.Col_Text, theme.col.text_muted)
  ImGui.TextWrapped(ctx,
    "Click connect to approve this plugin in your browser. The window stays open while it waits.")
  ImGui.PopStyleColor(ctx, 1)
  ImGui.PopFont(ctx)
  ImGui.Dummy(ctx, 0, 10)

  if primary_button(M.connecting and "Waiting for approval…" or "Connect to Mirelo", not M.connecting) then
    start_connect()
  end

  if M.auth_msg ~= "" then
    ImGui.Dummy(ctx, 0, 8)
    ImGui.PushFont(ctx, theme.fonts.sm)
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, theme.col.text_muted)
    ImGui.TextWrapped(ctx, M.auth_msg)
    ImGui.PopStyleColor(ctx, 1)
    ImGui.PopFont(ctx)
  end
  ImGui.PopFont(ctx)
end

-- Returns dur (clamped), raw_len, lim, ts0, ts1 for the given endpoint kind.
local function duration_clamped(kind)
  local ts0, ts1, len = R.time_selection()
  local lim = dur_limits(kind)
  local dur = len > 0 and clamp(len, lim.min, lim.max) or 0
  return dur, len, lim, ts0, ts1
end

-- Info / warning banner rendered as a tinted, bordered card (like the other
-- plugins' ToolDescription / WarningCard) so it stands out from the panel.
local banner_seq = 0 -- unique child id per call; a text-derived id collides when
                     -- two banners share text in one frame (e.g. an error string
                     -- equal to a static hint)
local function banner(text, kind)
  banner_seq = banner_seq + 1
  local is_warn = kind == "warn"
  local pad = 8
  local w = avail_w()
  ImGui.PushFont(ctx, theme.fonts.sm)
  -- Estimate wrapped height from the single-line width (robust regardless of
  -- how CalcTextSize handles the wrap arg); 0.88 leaves slack for word-wrap.
  local tw, line_h = ImGui.CalcTextSize(ctx, text)
  ImGui.PopFont(ctx)
  local content_w = math.max(1, w - 2 * pad - 2)
  local lines = math.max(1, math.ceil(tw / (content_w * 0.88)))
  local h = lines * line_h + 2 * pad + 2
  ImGui.PushStyleColor(ctx, ImGui.Col_ChildBg, is_warn and theme.col.warn_bg or theme.col.info_bg)
  ImGui.PushStyleColor(ctx, ImGui.Col_Border, is_warn and theme.col.warn_accent or theme.col.info_accent)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_ChildRounding, 4)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_WindowPadding, pad, pad)
  -- BeginChild must always be paired with EndChild, even when it returns false
  -- (e.g. the child is clipped/scrolled offscreen); otherwise the window stack
  -- is left unbalanced.
  if ImGui.BeginChild(ctx, "##bn" .. banner_seq, w, h, ImGui.ChildFlags_Border or 0) then
    ImGui.PushFont(ctx, theme.fonts.sm)
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, is_warn and theme.col.warn_text or theme.col.info_text)
    ImGui.TextWrapped(ctx, text)
    ImGui.PopStyleColor(ctx, 1)
    ImGui.PopFont(ctx)
  end
  ImGui.EndChild(ctx)
  ImGui.PopStyleVar(ctx, 2)
  ImGui.PopStyleColor(ctx, 2)
end

-- Three pulsing dots, drawn with the same DrawList primitives the tab icons
-- use, so the loading state needs no ReaImGui surface the rest of the UI
-- doesn't already depend on.
local function loading_dots()
  local dl = ImGui.GetWindowDrawList(ctx)
  local x, y = ImGui.GetCursorScreenPos(ctx)
  local w = avail_w()
  local t = reaper.time_precise()
  local cx = x + w / 2 - 14
  for i = 0, 2 do
    local lift = math.max(0, math.sin(((t * 1.6 - i * 0.18) % 1.0) * math.pi))
    -- The muted-text token with its alpha swapped for the pulse, so the dots
    -- stay on-palette without a colour of their own.
    local col = (theme.col.text_muted & 0xFFFFFF00) | math.floor(80 + 175 * lift)
    ImGui.DrawList_AddCircleFilled(dl, cx + i * 14, y + 5, 3.5, col)
  end
  ImGui.Dummy(ctx, w, 12)
end

-- A muted line centred in the content width.
local function centered_note(text)
  ImGui.PushFont(ctx, theme.fonts.sm)
  ImGui.PushStyleColor(ctx, ImGui.Col_Text, theme.col.text_muted)
  local tw = ImGui.CalcTextSize(ctx, text)
  ImGui.SetCursorPosX(ctx, ImGui.GetCursorPosX(ctx) + math.max(0, (avail_w() - tw) / 2))
  ImGui.Text(ctx, text)
  ImGui.PopStyleColor(ctx, 1)
  ImGui.PopFont(ctx)
end

-- Small amber explanatory line (e.g. why a checkbox is disabled).
local function hint(text)
  ImGui.PushFont(ctx, theme.fonts.xs or theme.fonts.sm)
  ImGui.PushStyleColor(ctx, ImGui.Col_Text, theme.col.warn_text)
  ImGui.TextWrapped(ctx, text)
  ImGui.PopStyleColor(ctx, 1)
  ImGui.PopFont(ctx)
end

-- Credit-cost subscript under the generate button (red when insufficient).
local function credit_line(needed)
  ImGui.PushFont(ctx, theme.fonts.sm)
  local ok = enough_credits(needed)
  ImGui.PushStyleColor(ctx, ImGui.Col_Text, ok and theme.col.text_muted or theme.col.toast_error)
  -- The capacity, not the ledger balance: this line exists to say whether the
  -- request will be funded, and those two numbers disagree with overage on or
  -- with a job of your own in flight. Showing the balance beside a gate that
  -- reads the capacity is how the line comes to say "available" in red.
  local avail = M.capacity ~= nil and ("  •  " .. commas(M.capacity) .. " available") or ""
  ImGui.Text(ctx, string.format("Needs %s credit%s%s", commas(needed), needed == 1 and "" or "s", avail))
  ImGui.PopStyleColor(ctx, 1)
  ImGui.PopFont(ctx)
end

-- Thin progress bar + stage message, shown while a job is in flight.
local function draw_progress()
  if not gen.is_busy() then return end
  local frac = gen.state.progress / 100
  local dl = ImGui.GetWindowDrawList(ctx)
  local x, y = ImGui.GetCursorScreenPos(ctx)
  local w = avail_w()
  ImGui.DrawList_AddRectFilled(dl, x, y, x + w, y + 4, theme.col.border, 2)
  ImGui.DrawList_AddRectFilled(dl, x, y, x + w * frac, y + 4, theme.col.progress_fill, 2)
  ImGui.Dummy(ctx, w, 6)
  ImGui.PushFont(ctx, theme.fonts.sm)
  ImGui.PushStyleColor(ctx, ImGui.Col_Text, theme.col.text_muted)
  ImGui.Text(ctx, gen.state.message .. "  " .. tostring(gen.state.progress) .. "%")
  ImGui.PopStyleColor(ctx, 1)
  ImGui.PopFont(ctx)
  ImGui.Dummy(ctx, 0, 4)
end

-- Shows the last generation error (every panel calls this so failures never
-- vanish silently).
local function draw_gen_error()
  if gen.state.status == "error" and gen.state.error then
    ImGui.Dummy(ctx, 0, 4)
    banner(gen.state.error, "warn")
  end
end

-- "Selected clip" card for the extender / inpainter.
local function draw_clip_card(clip)
  ImGui.PushStyleColor(ctx, ImGui.Col_ChildBg, theme.col.raised_bg)
  ImGui.PushStyleColor(ctx, ImGui.Col_Border, theme.col.border)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_ChildRounding, theme.space.radius_lg)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_WindowPadding, 10, 9)
  if ImGui.BeginChild(ctx, "clipcard", avail_w(), 56, ImGui.ChildFlags_Border or 0) then
    ImGui.PushStyleVar(ctx, ImGui.StyleVar_ItemSpacing, 8, 4)
    ImGui.PushFont(ctx, theme.fonts.xs or theme.fonts.sm)
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, theme.col.text_muted)
    ImGui.Text(ctx, "SELECTED CLIP")
    ImGui.PopStyleColor(ctx, 1)
    ImGui.PopFont(ctx)
    ImGui.PushFont(ctx, theme.fonts.sm)
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, theme.col.text)
    ImGui.Text(ctx, string.format("%s  (%.1fs)", clip.name, clip.item_len))
    ImGui.PopStyleColor(ctx, 1)
    ImGui.PopFont(ctx)
    ImGui.PopStyleVar(ctx, 1)
  end
  ImGui.EndChild(ctx) -- always paired with BeginChild, even when it returns false
  ImGui.PopStyleVar(ctx, 2)
  ImGui.PopStyleColor(ctx, 2)
  ImGui.Dummy(ctx, 0, theme.space.gap_sm)
end

local function draw_no_clip(verb)
  banner("Select an audio clip in REAPER to " .. verb .. ".", "warn")
end

local function draw_form()
  local noun = M.mode == "music" and "music" or "sound"
  -- Source selector — radio group, matching the DaVinci / Premiere plugins.
  ImGui.PushFont(ctx, theme.fonts.sm)
  ImGui.PushStyleColor(ctx, ImGui.Col_Text, theme.col.text_label)
  ImGui.Text(ctx, "Source")
  ImGui.PopStyleColor(ctx, 1)
  ImGui.Dummy(ctx, 0, 2)
  if radio("Text to " .. noun, M.source == "text") then M.source = "text" end
  if radio("Video to " .. noun, M.source == "video") then M.source = "video" end
  ImGui.PopFont(ctx)
  ImGui.Dummy(ctx, 0, theme.space.gap_sm)

  local kind = endpoint_kind()
  local is_video = M.source == "video"
  local dur, raw_len, lim, ts0, ts1 = duration_clamped(kind)
  local video_count = is_video and R.count_video_items_in_range(ts0, ts1) or 0

  if is_video then
    banner("Mirelo generates " .. noun .. " from the video itself — set a time range over your video clip.", "info")
    ImGui.Dummy(ctx, 0, theme.space.gap_xs)
  else
    -- Prompt.
    ImGui.PushFont(ctx, theme.fonts.sm)
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, theme.col.text_label)
    ImGui.Text(ctx, "Prompt")
    ImGui.PopStyleColor(ctx, 1)
    ImGui.PopFont(ctx)
    ImGui.PushStyleColor(ctx, ImGui.Col_FrameBg, theme.col.input_bg)
    local _, txt = ImGui.InputTextMultiline(ctx, "##prompt", M.prompt, avail_w(), 56)
    M.prompt = txt
    ImGui.PopStyleColor(ctx, 1)
    ImGui.Dummy(ctx, 0, theme.space.gap_sm)
  end

  -- Range / duration constraints (driven by the time selection).
  local too_short = raw_len > 0 and raw_len < lim.min
  local too_long = raw_len > lim.max
  if raw_len <= 0 then
    banner(is_video and "Set a time range over your video clip."
      or "Set a time selection in the timeline to choose the duration.", "warn")
  elseif is_video and video_count == 0 then
    banner("No video in the selected range. Move the range over a video clip.", "warn")
  elseif too_short then
    banner(string.format("Range too short — select at least %ss.", secs_text(lim.min)), "warn")
  elseif too_long then
    banner(string.format("Range too long — max %ss for this model.", secs_text(lim.max)), "warn")
  else
    ImGui.PushFont(ctx, theme.fonts.sm)
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, theme.col.text_muted)
    if is_video then
      ImGui.Text(ctx, string.format("Range: %s -> %s  (%.1fs)", R.format_tc(ts0), R.format_tc(ts1), dur))
    else
      ImGui.Text(ctx, string.format("Duration: %.1fs  (from time selection, %s-%ss)",
        dur, secs_text(lim.min), secs_text(lim.max)))
    end
    ImGui.PopStyleColor(ctx, 1)
    ImGui.PopFont(ctx)
  end
  ImGui.Dummy(ctx, 0, theme.space.gap_xs)

  -- Number of generations. The count carries across a mode switch, so it is
  -- clamped to the kind now selected rather than only bounded by the stepper.
  local max_samples = samples_max(kind)
  M.num_samples = clamp(M.num_samples, 1, max_samples)
  ImGui.PushFont(ctx, theme.fonts.sm)
  ImGui.PushStyleColor(ctx, ImGui.Col_Text, theme.col.text_label)
  ImGui.Text(ctx, "Generations")
  ImGui.PopStyleColor(ctx, 1)
  ImGui.SameLine(ctx, 0, 10)
  if card_button("-", 24) and M.num_samples > 1 then M.num_samples = M.num_samples - 1 end
  ImGui.SameLine(ctx, 0, 6)
  ImGui.Text(ctx, tostring(M.num_samples))
  ImGui.SameLine(ctx, 0, 6)
  if card_button("+", 24) and M.num_samples < max_samples then M.num_samples = M.num_samples + 1 end
  ImGui.PopFont(ctx)
  ImGui.Dummy(ctx, 0, theme.space.gap_sm)

  -- Progress (while busy).
  draw_progress()

  -- Generate.
  local needed = credits_for(dur, M.num_samples)
  local prompt_ok = is_video or (#M.prompt:gsub("%s", "") > 0)
  local range_ok = raw_len >= lim.min and raw_len <= lim.max and (not is_video or video_count > 0)
  local can_gen = (not gen.is_busy()) and range_ok and prompt_ok and enough_credits(needed)
  local action_label
  if gen.is_busy() then
    action_label = gen.state.message ~= "" and gen.state.message or "Working…"
  elseif is_video then
    action_label = M.mode == "music" and "Generate music from video" or "Generate sound from video"
  else
    action_label = M.mode == "music" and "Generate music" or "Generate sound effect"
  end
  if primary_button(action_label, can_gen) then
    if is_video then
      gen.start_video(kind, { duration_ms = math.floor(dur * 1000), num_samples = M.num_samples },
        ts0, { start = ts0, finish = ts1, len = raw_len })
    else
      gen.start_text(kind, {
        prompt = M.prompt,
        duration_ms = math.floor(dur * 1000),
        num_samples = M.num_samples,
      }, ts0)
    end
  end

  -- Credit cost subscript.
  if raw_len > 0 then credit_line(needed) end
  draw_gen_error()
end

local function source_duration(path)
  -- Quick length read for the playback cursor (best effort).
  local src = reaper.PCM_Source_CreateFromFile(path)
  if not src then return 0 end
  local len = reaper.GetMediaSourceLength(src)
  -- PCM_Source_Destroy is standard REAPER API; the guard only avoids crashing
  -- the loop on a hypothetical ABI where it's missing (nothing else could free
  -- the source there anyway).
  if reaper.PCM_Source_Destroy then reaper.PCM_Source_Destroy(src) end
  return len or 0
end

local function draw_result_card(item, grouped)
  ImGui.PushStyleColor(ctx, ImGui.Col_ChildBg, theme.col.raised_bg)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_ChildRounding, theme.space.radius_lg)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_WindowPadding, 8, 8)
  -- Grouped (inpaint pair) cards drop their own border + are inset; the group
  -- draws one border + a single × around them.
  local flags = grouped and 0 or (ImGui.ChildFlags_Border or 0)
  local cw = avail_w() - (grouped and 8 or 0)
  if ImGui.BeginChild(ctx, "card_" .. item.id, cw, 78, flags) then

  -- Header: name + per-card remove (×) — suppressed for grouped cards.
  ImGui.PushFont(ctx, theme.fonts.sm)
  ImGui.PushStyleColor(ctx, ImGui.Col_Text, theme.col.text_label)
  ImGui.Text(ctx, item.name or "Mirelo")
  ImGui.PopStyleColor(ctx, 1)
  ImGui.PopFont(ctx)
  if not grouped then
    ImGui.SameLine(ctx)
    ImGui.SetCursorPosX(ctx, ImGui.GetWindowWidth(ctx) - 26)
    if close_button("rm" .. item.id, 16) then M.pending_remove = item.id end
  end

  ImGui.Dummy(ctx, 0, 4)

  -- Playback row.
  local playing = M.play_idx == item.id
  if play_button("play_" .. item.id, playing, theme.space.play_sz) then
    if playing then
      R.stop_preview(); M.play_idx = nil
    else
      if R.preview(item.path) then
        M.play_idx = item.id
        M.play_started = reaper.time_precise()
        M.play_dur = source_duration(item.path)
      else
        toast("Preview needs the SWS extension; use Add instead.", "info")
      end
    end
  end
  ImGui.SameLine(ctx, 0, 8)

  -- Waveform (full width on the preview-only Original card; ADD reserved otherwise).
  local cached = M.wave[item.path]
  if not cached then
    local bars, real = wf.bars_for(item.path)
    cached = { bars = bars, real = real }
    M.wave[item.path] = cached
  end
  -- Always reserve the ADD slot so the Original and Inpainted waveforms are the
  -- SAME width and line up for A/B comparison (the Original just leaves it empty).
  local add_w = 56
  local wave_w = avail_w() - add_w - 12
  local wave_h = 30
  local wx, wy = ImGui.GetCursorScreenPos(ctx)
  local cursor_frac = nil
  if playing and M.play_dur > 0 then
    cursor_frac = clamp((reaper.time_precise() - M.play_started) / M.play_dur, 0, 1)
    if cursor_frac >= 1 then R.stop_preview(); M.play_idx = nil end
  end
  wf.draw(ctx, ImGui, wx, wy + 2, wave_w, wave_h, cached.bars, item.hi, cursor_frac)
  ImGui.Dummy(ctx, wave_w, wave_h)

  -- "Add" only on actionable outputs, not the original (before) comparison card.
  if not item.original then
    ImGui.SameLine(ctx, 0, 6)
    if card_button("ADD", add_w) then
      if gen.place(item) then
        toast("Added to a new track", "success")
      else
        toast("Couldn't place clip", "error")
      end
    end
  end

  end
  ImGui.EndChild(ctx) -- always paired with BeginChild, even when it returns false
  ImGui.PopStyleVar(ctx, 2)
  ImGui.PopStyleColor(ctx, 1)
  ImGui.Dummy(ctx, 0, 6)
end

local RESULT_HEADERS = {
  music = "Generated music",
  extend = "Generated extensions",
  inpaint = "Generated inpaints",
}

local function draw_results()
  -- Show only the active tab's outputs (each tool lists its own, like DaVinci),
  -- so the header always matches the cards beneath it.
  local items = {}
  for _, r in ipairs(gen.history) do
    if r.mode == M.mode then items[#items + 1] = r end
  end
  if #items == 0 then return end
  ImGui.Dummy(ctx, 0, theme.space.gap)
  ImGui.PushFont(ctx, theme.fonts.sm)
  ImGui.PushStyleColor(ctx, ImGui.Col_Text, theme.col.text_label)
  ImGui.Text(ctx, RESULT_HEADERS[M.mode] or "Generated sound effects")
  ImGui.PopStyleColor(ctx, 1)
  ImGui.PopFont(ctx)
  ImGui.Dummy(ctx, 0, 6)
  -- Consecutive items sharing a `pair` id (the inpaint Original+Inpainted) are
  -- wrapped in one bordered section so they read as a single output.
  local dl = ImGui.GetWindowDrawList(ctx)
  local i = 1
  while i <= #items do
    local item = items[i]
    if item.pair then
      ImGui.Dummy(ctx, 0, 6)
      local gx, gy = ImGui.GetCursorScreenPos(ctx)
      local gw = avail_w()
      local first = item
      ImGui.Indent(ctx, 8) -- inset the cards so the group box has visible padding
      local j = i
      while j <= #items and items[j].pair == item.pair do
        draw_result_card(items[j], true)
        j = j + 1
      end
      ImGui.Unindent(ctx, 8)
      local _, gy2 = ImGui.GetCursorScreenPos(ctx)
      -- The box around the whole inpaint pair (one output).
      ImGui.DrawList_AddRect(dl, gx, gy - 6, gx + gw, gy2 - 2, theme.col.group_border, theme.space.radius_lg, 0, 1.5)
      -- A single group-level × (top-right) — removes BOTH original + inpainted.
      ImGui.SetCursorScreenPos(ctx, gx + gw - 22, gy - 2)
      if close_button("rmg" .. first.pair, 16) then M.pending_remove = first.id end
      -- Return the cursor below the group and submit an item so ImGui grows the
      -- window to here (otherwise End() errors on the manual SetCursorScreenPos).
      ImGui.SetCursorScreenPos(ctx, gx, gy2)
      ImGui.Dummy(ctx, gw, 0)
      i = j
    else
      draw_result_card(item, false)
      i = i + 1
    end
  end
  if M.pending_remove then
    if M.play_idx ~= nil then R.stop_preview(); M.play_idx = nil end
    gen.remove(M.pending_remove)
    M.pending_remove = nil
    -- Evict waveform-cache entries for paths no longer in the history, so the
    -- table can't grow unbounded or (after a counter reset) serve stale bars.
    local live = {}
    for _, r in ipairs(gen.history) do
      if r.path then live[r.path] = true end
      if r._placed_path then live[r._placed_path] = true end
    end
    for path in pairs(M.wave) do
      if not live[path] then M.wave[path] = nil end
    end
  end
end

local function draw_toast()
  if not M.toast then return end
  if reaper.time_precise() > M.toast_until then M.toast = nil; return end
  local col = M.toast_kind == "success" and theme.col.toast_success
    or M.toast_kind == "error" and theme.col.toast_error
    or theme.col.toast_info
  ImGui.Dummy(ctx, 0, 6)
  ImGui.PushFont(ctx, theme.fonts.sm)
  ImGui.PushStyleColor(ctx, ImGui.Col_Text, col)
  ImGui.Text(ctx, M.toast)
  ImGui.PopStyleColor(ctx, 1)
  ImGui.PopFont(ctx)
end

local function draw_extender()
  banner("Seamlessly extend an audio clip with natural-sounding audio.", "info")
  ImGui.Dummy(ctx, 0, theme.space.gap_xs)
  -- While a job is in flight, keep showing the clip it's processing (and its
  -- progress) even if the user deselects the timeline — never hide progress.
  local clip = (gen.is_busy() and gen.state.active_clip) or R.get_selected_clip()
  if not clip then
    if gen.is_busy() then draw_progress(); draw_gen_error() else draw_no_clip("extend") end
    return
  end
  draw_clip_card(clip)

  -- The prefix the model conditions on is the clip's SOURCE content
  -- (item_len * take_playrate), matching gen.start_extend; rate == 1 is the
  -- common case. The extension itself is new audio, so it isn't rate-scaled.
  local rate = (clip.take_playrate and clip.take_playrate ~= 0) and clip.take_playrate or 1
  local foot = clip.item_len * rate
  local requires_auto_trim = (foot + M.extension) > EXT_TOTAL_MAX

  -- Video coverage forward from the clip's right edge (where the extension lands).
  local window_start = clip.item_pos + clip.item_len
  local cov = vc.compute(R.get_video_intervals(window_start), window_start)
  -- Loop takes precedence over video (Modal's loop endpoint rejects video).
  local loop_candidate = M.loop and not requires_auto_trim
  local has_reach = cov.max_gap_free > 1e-3
  local fits = cov.max_gap_free + 1e-3 >= M.extension
  -- Why "Use video" is unavailable (nil = available) — shown under the toggle.
  local video_reason
  if loop_candidate then
    video_reason = "Turn off loop to use video conditioning."
  elseif not has_reach then
    video_reason = "No video covers the area right after this clip — add a video clip to enable."
  elseif not fits then
    video_reason = string.format(
      "Video only covers %.1fs after the clip. Shorten the extension to %.1fs or less to enable.",
      cov.max_gap_free, cov.max_gap_free)
  end
  local video_enabled = video_reason == nil
  local eff_video = M.ext_use_video and video_enabled
  local eff_loop = loop_candidate and not eff_video
  -- Why "Make extension loopable" is unavailable.
  local loop_reason
  if eff_video then
    loop_reason = "Turn off video to enable looping."
  elseif requires_auto_trim then
    loop_reason = string.format(
      "Loop needs the clip + extension to total %.0fs or less. Shorten the extension to enable.",
      EXT_TOTAL_MAX)
  end
  local loop_enabled = loop_reason == nil
  -- v3 publishes one append ceiling for extend, video-guided or not, so the
  -- only thing the video leg narrows it by is how far the video actually runs.
  local ext = M.limits.extend
  local min_ext = eff_loop and ext.min_with_loop or ext.min
  local ext_max = eff_video and math.min(ext.max, cov.max_gap_free) or ext.max

  -- "Extend by" stepper (0.1s grain).
  ImGui.PushFont(ctx, theme.fonts.sm)
  ImGui.PushStyleColor(ctx, ImGui.Col_Text, theme.col.text_label)
  ImGui.Text(ctx, "Extend by")
  ImGui.PopStyleColor(ctx, 1)
  ImGui.SameLine(ctx, 0, 10)
  if card_button("-", 26) then M.extension = clamp(round1(M.extension - 0.1), min_ext, ext_max) end
  ImGui.SameLine(ctx, 0, 6)
  -- Editable seconds field (type a value, or use the steppers).
  ImGui.PushItemWidth(ctx, 56)
  ImGui.PushStyleColor(ctx, ImGui.Col_FrameBg, theme.col.input_bg)
  local ech, ev = ImGui.InputDouble(ctx, "##extsec", M.extension, 0, 0, "%.1f")
  ImGui.PopStyleColor(ctx, 1)
  ImGui.PopItemWidth(ctx)
  if ech then M.extension = clamp(round1(ev), min_ext, ext_max) end
  ImGui.SameLine(ctx, 0, 4)
  ImGui.Text(ctx, "s")
  ImGui.SameLine(ctx, 0, 6)
  if card_button("+", 26) then M.extension = clamp(round1(M.extension + 0.1), min_ext, ext_max) end
  ImGui.PopFont(ctx)
  M.extension = clamp(round1(M.extension), min_ext, ext_max)
  ImGui.Dummy(ctx, 0, theme.space.gap_xs)

  -- "Use video to guide extension" (always shows why it's disabled).
  ImGui.PushFont(ctx, theme.fonts.sm)
  if not video_enabled then ImGui.BeginDisabled(ctx) end
  local _, vv = checkbox("Use video to guide extension", M.ext_use_video and video_enabled)
  if not video_enabled then ImGui.EndDisabled(ctx) else M.ext_use_video = vv end
  ImGui.PopFont(ctx)
  if video_reason then hint(video_reason) end
  ImGui.Dummy(ctx, 0, theme.space.gap_xs)

  -- "Make extension loopable" (always shows why it's disabled).
  ImGui.PushFont(ctx, theme.fonts.sm)
  if not loop_enabled then ImGui.BeginDisabled(ctx) end
  local _, lv = checkbox("Make extension loopable", M.loop and loop_enabled)
  if not loop_enabled then ImGui.EndDisabled(ctx) else M.loop = lv end
  ImGui.PopFont(ctx)
  if loop_reason then hint(loop_reason) end
  ImGui.Dummy(ctx, 0, theme.space.gap_xs)

  -- Validation (validateExtenderIntent).
  local reason
  if foot < PREFIX_MIN then
    reason = string.format("Selected clip must be at least %.0f seconds (currently %.1fs).", PREFIX_MIN, foot)
  elseif M.extension < min_ext then
    reason = string.format("Extension must be at least %ss%s.",
      secs_text(min_ext), eff_loop and " when loop is enabled" or "")
  elseif M.extension > ext.max then
    reason = string.format("Extension cannot exceed %s seconds.", secs_text(ext.max))
  elseif eff_loop and (foot + M.extension) > EXT_TOTAL_MAX then
    reason = string.format("Total cannot exceed %.0fs when loop is enabled.", EXT_TOTAL_MAX)
  end
  if reason then banner(reason, "warn") end

  draw_progress()

  local needed = credits_for(M.extension, 1)
  local can = (not gen.is_busy()) and reason == nil and enough_credits(needed)
  local label = gen.is_busy() and (gen.state.message ~= "" and gen.state.message or "Working…")
    or string.format("Extend by %.1fs", M.extension)
  if primary_button(label, can) then
    gen.start_extend({ extension_seconds = M.extension, loop = eff_loop, use_video = eff_video }, clip)
  end
  credit_line(needed)
  draw_gen_error()
end

local function draw_inpainter()
  banner("Replace part of a clip — select the clip and a time range inside it.", "info")
  ImGui.Dummy(ctx, 0, theme.space.gap_xs)
  -- Keep the in-flight clip + progress visible even if the timeline selection changes.
  local clip = (gen.is_busy() and gen.state.active_clip) or R.get_selected_clip()
  if not clip then
    if gen.is_busy() then draw_progress(); draw_gen_error() else draw_no_clip("inpaint") end
    return
  end
  draw_clip_card(clip)

  local clip_start, clip_end = clip.item_pos, clip.item_pos + clip.item_len
  local rs, re = clip.ts_start, clip.ts_end
  local has_range = re > rs
  -- The model regenerates SOURCE audio, so the API limits and credit cost use the
  -- source-domain gap (timeline selection * take playrate), matching
  -- gen.start_inpaint. rate == 1 (the common case) keeps these equal to the
  -- timeline values; the displayed selection length below stays timeline-based.
  local rate = (clip.take_playrate and clip.take_playrate ~= 0) and clip.take_playrate or 1
  local source_gap = has_range and (re - rs) * rate or 0

  ImGui.PushFont(ctx, theme.fonts.sm)
  ImGui.PushStyleColor(ctx, ImGui.Col_Text, theme.col.text_muted)
  if has_range then
    ImGui.Text(ctx, string.format("Replace: %s -> %s  (%.1fs)", R.format_tc(rs), R.format_tc(re), re - rs))
  else
    ImGui.Text(ctx, "Set a time range inside the clip to replace.")
  end
  ImGui.PopStyleColor(ctx, 1)
  ImGui.PopFont(ctx)
  ImGui.Dummy(ctx, 0, theme.space.gap_xs)

  -- Validation (validateInpaintIntent).
  local reason
  if not has_range then
    reason = "Set In/Out points around the part of the clip to replace."
  elseif rs < clip_start or rs >= clip_end then
    reason = "The range must start inside the selected clip."
  elseif re > clip_end then
    reason = "The range must end inside the selected clip."
  else
    local inp = M.limits.inpaint
    local source_offset = clip.take_startoffs + (rs - clip_start) * rate
    if source_offset < inp.start_min then
      reason = string.format("Range must start at least %ss into the source audio.",
        secs_text(inp.start_min))
    elseif source_gap < inp.gap_min then
      reason = string.format("Selection must be at least %ss long.", secs_text(inp.gap_min))
    elseif source_gap > inp.gap_max then
      reason = string.format("Selection cannot exceed %ss.", secs_text(inp.gap_max))
    end
  end
  if reason then banner(reason, "warn") end

  draw_progress()

  local needed = credits_for(source_gap, 1)
  local can = (not gen.is_busy()) and reason == nil and enough_credits(needed)
  local label = gen.is_busy() and (gen.state.message ~= "" and gen.state.message or "Working…")
    or "Inpaint selection"
  if primary_button(label, can) then gen.start_inpaint(clip) end
  credit_line(needed)
  draw_gen_error()
end

-- Tear down the session: stop preview, drop in-flight requests + generation
-- state, clear the key, and return to the connect screen. Shared by the manual
-- Disconnect button and the automatic auth-failure handler.
local function logout()
  R.stop_preview()
  net.reset()
  gen.reset()
  store.clear_api_key()
  M.route = "auth"; M.connecting = false; M.capacity = nil
  M.wave = {}; M.play_idx = nil
  -- net.reset() dropped any in-flight requests, so their callbacks won't run.
  -- Reset the flags those callbacks would have cleared, or the next session gets
  -- stuck: fetch_me would early-return forever (blank credits), the registry
  -- fetch would sit on "loading" with nothing left to answer it, and the
  -- feedback modal would stay on "Sending…".
  M.me_inflight = false
  M.limits = nil
  M.models_status = "idle"; M.models_inflight = false
  M.models_epoch = M.models_epoch + 1
  M.feedback_status = "idle"; M.feedback_error = ""
end

-- Feedback + disconnect modals (opened from the header).
local function draw_modals()
  -- AlwaysAutoResize so the window grows to fit a status/error line — it can
  -- never overflow and hide the buttons.
  if ImGui.BeginPopupModal(ctx, "Send feedback", nil, ImGui.WindowFlags_AlwaysAutoResize or 0) then
    local box_w = 300
    ImGui.PushFont(ctx, theme.fonts.sm)
    ImGui.PushTextWrapPos(ctx, box_w)
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, theme.col.text_muted)
    ImGui.TextWrapped(ctx, "Tell us what's working or what's missing — we read every note.")
    ImGui.PopStyleColor(ctx, 1)
    ImGui.Dummy(ctx, 0, 6)
    ImGui.PushStyleColor(ctx, ImGui.Col_FrameBg, theme.col.input_bg)
    local changed, txt = ImGui.InputTextMultiline(ctx, "##fb", M.feedback_text, box_w, 90)
    ImGui.PopStyleColor(ctx, 1)
    if changed then
      M.feedback_text = txt
      -- Editing clears a previous error/sent state so it disappears.
      if M.feedback_status ~= "sending" then M.feedback_status = "idle" end
    end
    ImGui.Dummy(ctx, 0, 8)
    -- Buttons FIRST so Close is always reachable regardless of the status text.
    local sending = M.feedback_status == "sending"
    local can_send = (not sending) and #M.feedback_text:gsub("%s", "") > 0
    if not can_send then ImGui.BeginDisabled(ctx) end
    if ImGui.Button(ctx, sending and "Sending…" or "Send", 110, 26) then
      M.feedback_status = "sending"; M.feedback_error = ""
      api.submit_feedback(M.feedback_text, function(err)
        if err then
          M.feedback_status = "error"; M.feedback_error = err
        else
          M.feedback_status = "sent"; M.feedback_text = ""
        end
      end)
    end
    if not can_send then ImGui.EndDisabled(ctx) end
    ImGui.SameLine(ctx, 0, 8)
    if ImGui.Button(ctx, M.feedback_status == "sent" and "Close" or "Cancel", 90, 26) then
      ImGui.CloseCurrentPopup(ctx)
    end
    -- Status / error UNDER the buttons.
    if M.feedback_status == "sent" then
      ImGui.Dummy(ctx, 0, 4)
      ImGui.PushStyleColor(ctx, ImGui.Col_Text, theme.col.toast_success)
      ImGui.TextWrapped(ctx, "Thanks — feedback sent!")
      ImGui.PopStyleColor(ctx, 1)
    elseif M.feedback_status == "error" then
      ImGui.Dummy(ctx, 0, 4)
      ImGui.PushStyleColor(ctx, ImGui.Col_Text, theme.col.toast_error)
      ImGui.TextWrapped(ctx, M.feedback_error)
      ImGui.PopStyleColor(ctx, 1)
    end
    ImGui.PopTextWrapPos(ctx)
    ImGui.PopFont(ctx)
    ImGui.EndPopup(ctx)
  end

  ImGui.SetNextWindowSize(ctx, 300, 0, ImGui.Cond_Appearing)
  if ImGui.BeginPopupModal(ctx, "Disconnect", nil, ImGui.WindowFlags_NoResize or 0) then
    ImGui.PushFont(ctx, theme.fonts.sm)
    ImGui.TextWrapped(ctx, "Disconnect from your Mirelo account? You'll need to reconnect to generate again.")
    ImGui.PopFont(ctx)
    ImGui.Dummy(ctx, 0, 10)
    ImGui.PushStyleColor(ctx, ImGui.Col_Button, theme.col.toast_error)
    ImGui.PushStyleColor(ctx, ImGui.Col_ButtonHovered, theme.col.toast_error)
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0xFFFFFFFF)
    if ImGui.Button(ctx, "Disconnect", 110, 26) then
      logout()
      ImGui.CloseCurrentPopup(ctx)
    end
    ImGui.PopStyleColor(ctx, 3)
    ImGui.SameLine(ctx, 0, 8)
    if ImGui.Button(ctx, "Cancel", 80, 26) then ImGui.CloseCurrentPopup(ctx) end
    ImGui.EndPopup(ctx)
  end
end

-- Blocking screen shown when this build is no longer supported.
local function draw_version_blocked()
  ImGui.Dummy(ctx, 0, 20)
  ImGui.PushFont(ctx, theme.fonts.base)
  ImGui.TextColored(ctx, theme.col.text, "Plugin update required")
  ImGui.PopFont(ctx)
  ImGui.Dummy(ctx, 0, 8)
  banner(M.version_blocked.message, "warn")
  if M.version_blocked.url and M.version_blocked.url ~= "" then
    ImGui.Dummy(ctx, 0, 12)
    if primary_button("Download update", true) then R.open_url(M.version_blocked.url) end
  end
end

-- Stands in for the whole generation form until `GET /v3/models` answers.
--
-- Every bound the form draws comes from there, and there is deliberately no
-- fallback to compiled numbers: rendering sliders against a guessed bound
-- refuses requests the API would accept and only says so at generate time,
-- which is worse than saying it here.
local function draw_models_gate()
  if M.models_status == "error" then
    banner("The Mirelo API is unavailable, so the generation options couldn't be loaded. "
      .. "Check your connection, then retry.", "warn")
    ImGui.Dummy(ctx, 0, theme.space.gap_sm)
    if primary_button("Retry", true) then fetch_models() end
    return
  end
  ImGui.Dummy(ctx, 0, 24)
  loading_dots()
  ImGui.Dummy(ctx, 0, 10)
  centered_note("Loading generation options…")
end

local function draw_main()
  -- "Update available" notice (dismissible).
  if M.version_notice then
    banner(M.version_notice.message, "warn")
    local has_url = M.version_notice.url and M.version_notice.url ~= ""
    if has_url then
      if card_button("Update", 70) then R.open_url(M.version_notice.url) end
      ImGui.SameLine(ctx, 0, 6)
    end
    if card_button("Dismiss", 70) then
      M.version_dismissed = M.version_notice.message
      M.version_notice = nil
    end
    ImGui.Dummy(ctx, 0, theme.space.gap_xs)
  end

  ImGui.PushFont(ctx, theme.fonts.sm)
  M.mode = segmented("mode", {
    { id = "sfx", label = "SFX", icon = "sfx" },
    { id = "music", label = "Music", icon = "music" },
    { id = "extend", label = "Extend", icon = "extend" },
    { id = "inpaint", label = "Inpaint", icon = "inpaint" },
  }, M.mode)
  ImGui.PopFont(ctx)
  ImGui.Dummy(ctx, 0, theme.space.gap_sm)
  -- Music is the one tool whose bounds are compiled in (no v3 music family), so
  -- it stays usable while the registry is still loading or has given up.
  if M.mode ~= "music" and M.models_status ~= "ready" then
    draw_models_gate()
  elseif M.mode == "extend" then
    draw_extender()
  elseif M.mode == "inpaint" then
    draw_inpainter()
  else
    draw_form()
  end
  draw_toast()
  draw_results()
end

-- ---- public ---------------------------------------------------------------

-- The registry fetch's own tick and state.
--
-- ui.draw drives `update` once per frame and the gate reads `status`; this
-- handle exists so the loading / retry / deadline machine can also be driven
-- and read without an ImGui frame, which is what makes the failure half —
-- the half that never fires in normal use — reachable from the unit suite.
ui.registry = {
  fetch = function() fetch_models() end,
  update = function() update_models() end,
  status = function() return M.models_status end,
  limits = function() return M.limits end,
}

function ui.init(imgui_mod, context, logo_img, icons)
  ImGui, ctx, logo = imgui_mod, context, logo_img
  M.icons = icons or {}
  -- Any auth failure anywhere drops back to the connect screen.
  api.on_auth_error = function()
    -- Already disconnected: a detached upload/submit/poll from a torn-down job
    -- can 401 after a deliberate logout. The key is gone, so ignore it rather
    -- than re-resetting and flashing a misleading "connection expired" toast.
    if not store.api_key() then return end
    logout()
    toast("Your Mirelo connection expired — reconnect.", "error")
  end
  if store.api_key() then
    M.route = "main"
    fetch_me()
    fetch_models()
  else
    M.route = "auth"
  end
end

-- Called once per frame between Begin/End.
function ui.draw()
  gen.update()
  -- On the busy -> done transition: refresh credits (the job just spent some) and
  -- surface a partial-sample failure once, rather than completing silently.
  local busy = gen.is_busy()
  if M._was_busy and not busy and gen.state.status == "done" then
    fetch_me()
    -- Two ways a batch comes back short, and both are worth saying: v3 can
    -- deliver fewer variants than were asked for (billed on the count asked
    -- for either way), and a delivered one can fail to download.
    local short = (gen.state._dl_failed or 0) + (gen.state._undelivered or 0)
    if short > 0 then
      local asked = (gen.state._dl_total or 0) + (gen.state._undelivered or 0)
      toast(string.format("%d of %d samples didn't come back", short, asked), "info")
    end
  end
  M._was_busy = busy

  update_auth()
  update_models()
  if reaper.time_precise() >= M.version_next_check then
    M.version_next_check = reaper.time_precise() + VERSION_RECHECK
    check_version()
  end

  draw_header()
  if M.version_blocked then
    draw_version_blocked()
  elseif M.route == "auth" or M.route == "loading" then
    draw_auth()
  else
    draw_main()
  end
  -- Modals last + unconditionally, so the header's Feedback/Logout work on every
  -- screen (incl. the blocked screen, where draw_main isn't called).
  draw_modals()
end

return ui
