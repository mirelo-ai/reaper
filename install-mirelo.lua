-- @noindex
-- Mirelo installer — run this ONCE in REAPER to install (and keep updated) the
-- Mirelo plugin via ReaPack. After it finishes, run the "Mirelo" action.
--
-- How to run: Actions > Show action list > New action > "Load ReaScript..." >
-- pick this file > Run. (REAPER runs .lua itself — you don't need Lua installed.)
--
-- This adds the Mirelo ReaPack repository and enables auto-install, so future
-- updates arrive through ReaPack's normal "Synchronize". You can delete this
-- installer action afterwards.

local REPO_NAME = "Mirelo"
-- Public ReaPack index (served from the github.com/mirelo-ai/reaper repo).
-- ReaPack fetches this over HTTPS, so it must stay publicly reachable.
local INDEX_URL = "https://raw.githubusercontent.com/mirelo-ai/reaper/main/index.xml"

local function msg(text) reaper.ShowMessageBox(text, "Mirelo installer", 0) end

-- ReaPack is a C++ extension and can't be bootstrapped from Lua; the user must
-- install it first. Detect it by the presence of its ReaScript API.
if not reaper.ReaPack_AddSetRepository then
  msg("ReaPack isn't installed.\n\n"
    .. "1. Install ReaPack from https://reapack.com\n"
    .. "2. Restart REAPER\n"
    .. "3. Run this installer again.")
  return
end

-- name, url, enable, autoInstall(1 = install on sync). Returns ok, error.
local ok, err = reaper.ReaPack_AddSetRepository(REPO_NAME, INDEX_URL, true, 1)
if not ok then
  msg("Couldn't add the Mirelo repository:\n\n" .. tostring(err)
    .. "\n\nYou can add it manually: Extensions > ReaPack > Import repositories, then paste:\n"
    .. INDEX_URL)
  return
end

-- Sync now so Mirelo installs immediately (ReaPack shows its own progress).
reaper.ReaPack_ProcessQueue(true)

msg("Mirelo is being installed via ReaPack.\n\n"
  .. "When it finishes, open the Actions list, search \"Mirelo\", and run it.\n\n"
  .. "Mirelo needs the ReaImGui extension (>= 0.9). If it isn't installed, the "
  .. "plugin will prompt you — install it from ReaPack (Browse packages).\n\n"
  .. "You can remove this installer action now; updates come through ReaPack.")
