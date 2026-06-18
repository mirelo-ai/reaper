-- Design tokens transcribed from the DaVinci Resolve plugin's Tailwind theme so
-- the ReaImGui surface reads as the same product. ImGui colours are 0xRRGGBBAA.

local theme = {}

-- rgba(0xRRGGBB, alpha 0..255) -> 0xRRGGBBAA
local function rgba(rgb, a)
  return (rgb << 8) | (a & 0xFF)
end
theme.rgba = rgba

-- Raw 24-bit brand/neutral values (mirror the spec table).
local C = {
  window      = 0x1C1F22, -- app backdrop (charcoal, matching the DaVinci panel)
  panel       = 0x1C1F22, -- PanelFrame / main container bg
  neutral_900 = 0x18181B, -- inputs, toggle track
  neutral_800 = 0x27272A, -- active tab, borders, disabled fill
  neutral_700 = 0x3F3F46, -- hover, subtle border
  neutral_600 = 0x52525B,
  neutral_500 = 0x71717A, -- secondary text
  neutral_400 = 0xA1A1AA, -- muted/helper text
  neutral_300 = 0xD4D4D8, -- header labels
  neutral_200 = 0xE4E4E7, -- primary text
  sky_500     = 0x0EA5E9, -- primary CTA
  sky_400     = 0x38BDF8, -- CTA hover
  sky_300     = 0x7DD3FC, -- progress %, links
  sky_950     = 0x0C2D4A, -- info banner bg
  emerald_700 = 0x059669, -- success toast
  destructive = 0xEF4444, -- error toast / warning
  amber_200   = 0xFCD34D, -- warning card text
  wave_green  = 0x7DD17D, -- waveform bars / play glyph
  wave_amber  = 0xFFB84D, -- extension marker
  card_btn    = 0x1E201F, -- ADD/play button bg
  card_btn_hi = 0x252825, -- ADD/play button hover
  white       = 0xFFFFFF,
}

-- Pre-baked ImGui colours (full alpha unless noted) used across the UI.
theme.col = {
  window_bg   = rgba(C.window, 0xFF),
  panel_bg    = rgba(C.panel, 0xFF),
  raised_bg   = rgba(0x262A2E, 0xFF), -- a touch lighter than the window so cards raise
  input_bg    = rgba(C.neutral_900, 0xFF),
  border      = rgba(C.neutral_800, 0xFF),
  group_border = rgba(C.neutral_500, 0xFF), -- clearly visible box around an inpaint pair

  text        = rgba(C.neutral_200, 0xFF),
  text_label  = rgba(C.neutral_300, 0xFF),
  text_muted  = rgba(C.neutral_400, 0xFF),
  text_faint  = rgba(C.neutral_500, 0xFF),

  tab_track   = rgba(C.neutral_900, 0xFF),
  tab_active  = rgba(C.neutral_800, 0xFF),

  cta         = rgba(C.sky_500, 0xE6), -- bg-sky-500/90
  cta_hover   = rgba(C.sky_400, 0xFF),
  cta_text    = rgba(0x0A0A0A, 0xFF),  -- neutral-950
  cta_disabled = rgba(C.neutral_700, 0xFF),
  cta_disabled_text = rgba(C.neutral_400, 0xFF),

  progress_fill = rgba(C.sky_300, 0xFF),

  toast_success = rgba(C.emerald_700, 0xE6),
  toast_error   = rgba(C.destructive, 0xE6),
  toast_info    = rgba(0x0369A1, 0xE6), -- sky-700/90

  info_bg     = rgba(C.sky_950, 0xF2), -- info banner card
  info_accent = rgba(C.sky_400, 0xFF),
  info_text   = rgba(0xE0F2FE, 0xFF),  -- sky-50

  warn_bg     = rgba(0x3A2A12, 0xFF),  -- warm amber-tinted card
  warn_accent = rgba(C.amber_200, 0xFF),
  warn_text   = rgba(C.amber_200, 0xFF),

  -- Checkboxes: lighter box + bright tick so they read on the dark panel.
  check_mark        = rgba(C.sky_400, 0xFF),
  checkbox_bg       = rgba(C.neutral_700, 0xFF),
  checkbox_bg_hover = rgba(C.neutral_600, 0xFF),
  checkbox_border   = rgba(C.neutral_500, 0xFF),

  wave        = rgba(C.wave_green, 0xFF),
  wave_ext    = rgba(C.wave_amber, 0xFF),
  cursor      = rgba(C.white, 0xFF),

  card_btn    = rgba(C.card_btn, 0xFF),
  card_btn_hi = rgba(C.card_btn_hi, 0xFF),
  play_glyph  = rgba(C.wave_green, 0xFF),
}

-- Spacing scale (px) — Tailwind 1 = 4px.
theme.space = {
  panel_pad   = 12, -- px-3 py-3
  gap         = 16, -- gap-4 between major blocks
  gap_sm      = 12, -- gap-3 between form rows
  gap_xs      = 6,  -- gap-1.5
  radius_sm   = 4,  -- rounded-sm
  radius_lg   = 8,  -- rounded-lg
  btn_h       = 32, -- h-8 generate button
  play_sz     = 28, -- h-7 w-7
}

-- Font pixel sizes used across the UI. The entry script bakes one ImGui font
-- per size and stashes the handles here at startup.
theme.font_sizes = { xs = 11, sm = 12, base = 14 }
theme.fonts = {} -- filled in by mirelo.lua: fonts.xs, fonts.sm, fonts.base

return theme
