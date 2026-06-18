-- @description Mirelo — AI sound effects & music for REAPER
-- @version 0.1.0
-- @author Mirelo
-- @link Website https://mirelo.ai
-- @provides
--   [nomain] mirelo/*.lua
--   resources/*.png
-- @about
--   # Mirelo for REAPER
--
--   Generate sound effects and music from a text prompt or the video on your
--   timeline, and extend or inpaint audio clips — all inside REAPER, powered by
--   Mirelo (https://mirelo.ai).
--
--   ## Requirements
--   - ReaImGui >= 0.9 — install via ReaPack (Extensions > ReaPack > Browse packages).
--   - curl >= 7.73 — in-box on Windows 10 1803+, macOS, and modern Linux.
--   - SWS extension — optional; enables in-panel audio preview.
--
--   Run the "Mirelo" action to open the dockable window, then connect your account.
-- @changelog
--   First release: Text/Video to SFX & Music, Extender, Inpainter; device-nonce
--   auth, live credit display, and a startup version gate.

-- Mirelo for REAPER — pure ReaScript + ReaImGui edition.
-- Single-script companion: no Electron, no bridge process, no installer.
-- Run this as an Action; it opens a dockable ImGui window.
--
-- The @version above tracks the base of api.PLUGIN_VERSION (the variant-tagged
-- string sent to /plugin/check-version); bump both together on a release.
--
-- Requirements: ReaImGui (cfillion) >= 0.9 via ReaPack, and curl >= 7.73
-- (in-box on Windows 10 1803+, macOS, modern Linux). SWS is optional (enables
-- in-panel preview).

-- ---- resolve our own directory and wire module paths ----------------------
local SEP = package.config:sub(1, 1)
local _, script_path = reaper.get_action_context()
local script_dir = script_path:match("^(.*[/\\])") or ("." .. SEP)
package.path = script_dir .. "?.lua;" .. package.path

-- ---- ReaImGui presence check ----------------------------------------------
if not reaper.ImGui_GetBuiltinPath then
  reaper.ShowMessageBox(
    "ReaImGui is required.\n\nInstall it via ReaPack:\n  Extensions > ReaPack > Browse packages > \"ReaImGui\"",
    "Mirelo", 0)
  return
end
package.path = reaper.ImGui_GetBuiltinPath() .. "/?.lua;" .. package.path
local ImGui = require("imgui") "0.9"

-- ---- our modules ----------------------------------------------------------
local theme = require("mirelo.theme")
local net   = require("mirelo.net")
local ui    = require("mirelo.ui")

-- ---- context, fonts, assets ----------------------------------------------
local ctx = ImGui.CreateContext("Mirelo")

local function make_font(size)
  local font = ImGui.CreateFont("sans-serif", size, 0)
  ImGui.Attach(ctx, font)
  return font
end
theme.fonts.xs   = make_font(theme.font_sizes.xs)
theme.fonts.sm   = make_font(theme.font_sizes.sm)
theme.fonts.base = make_font(theme.font_sizes.base)

local function load_image(name)
  local ok, img = pcall(ImGui.CreateImage, script_dir .. "resources" .. SEP .. name)
  if ok and img then
    ImGui.Attach(ctx, img)
    return img
  end
  return nil
end

local logo = load_image("logo-dark.png")

-- Tool icons (the Premiere plugin's dark-theme icons, reused verbatim).
local tab_icons = {}
for _, k in ipairs({ "sfx", "music", "extend", "inpaint" }) do
  tab_icons[k] = load_image("icon-" .. k .. ".png")
end

net.init()
ui.init(ImGui, ctx, logo, tab_icons)

-- ---- base style (pushed each frame, popped after End) ---------------------
local STYLE_COLORS = {
  { ImGui.Col_WindowBg,        theme.col.window_bg },
  { ImGui.Col_ChildBg,         theme.col.panel_bg },
  { ImGui.Col_Text,            theme.col.text },
  { ImGui.Col_TextDisabled,    theme.col.text_faint },
  { ImGui.Col_FrameBg,         theme.col.input_bg },
  { ImGui.Col_FrameBgHovered,  theme.col.border },
  { ImGui.Col_FrameBgActive,   theme.col.border },
  { ImGui.Col_Border,          theme.col.border },
  { ImGui.Col_Separator,       theme.col.border },
  { ImGui.Col_PopupBg,         theme.col.panel_bg },
  { ImGui.Col_ScrollbarBg,     0x00000000 },
  { ImGui.Col_ScrollbarGrab,   theme.col.border },
}

local function push_style()
  for _, c in ipairs(STYLE_COLORS) do
    ImGui.PushStyleColor(ctx, c[1], c[2])
  end
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_WindowPadding, theme.space.panel_pad, theme.space.panel_pad)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_FramePadding, 10, 6)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_ItemSpacing, 8, 7)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_FrameRounding, theme.space.radius_sm)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_ChildRounding, theme.space.radius_lg)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_WindowBorderSize, 0)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_FrameBorderSize, 0)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_ScrollbarSize, 9)
end

local function pop_style()
  ImGui.PopStyleVar(ctx, 8)
  ImGui.PopStyleColor(ctx, #STYLE_COLORS)
end

-- ---- main loop ------------------------------------------------------------
local function loop()
  push_style()
  ImGui.SetNextWindowSize(ctx, 360, 640, ImGui.Cond_FirstUseEver)
  local visible, open = ImGui.Begin(ctx, "Mirelo", true)
  if visible then
    ImGui.PushFont(ctx, theme.fonts.base)
    ui.draw()
    ImGui.PopFont(ctx)
  end
  ImGui.End(ctx) -- always paired with Begin, even when collapsed (visible == false)
  pop_style()

  if open then
    reaper.defer(loop)
  else
    require("mirelo.reaper_io").stop_preview()
    -- Full teardown: aborts an in-flight render (restoring its settings) and GCs
    -- the render/upload temps plus any unplaced downloaded results.
    require("mirelo.generation").reset()
    net.reset() -- drop in-flight curl requests + their temp config/body files
  end
end

reaper.defer(loop)
