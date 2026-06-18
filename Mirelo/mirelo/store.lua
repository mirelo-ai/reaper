-- Persisted settings via REAPER's ExtState (survives restarts, written to
-- reaper-extstate.ini). The API key lives here in plaintext — the same posture
-- as the Electron build's localStorage, and the same open security decision
-- (migrate to an OS keychain later). Flagged in README.

local SECTION = "Mirelo"

local store = {}

function store.get(key, default)
  local v = reaper.GetExtState(SECTION, key)
  if v == nil or v == "" then return default end
  return v
end

function store.set(key, value)
  -- persist = true -> survives REAPER restart
  reaper.SetExtState(SECTION, key, value or "", true)
end

function store.clear(key)
  reaper.DeleteExtState(SECTION, key, true)
end

-- Convenience wrappers for the values the app cares about.
function store.api_key() return store.get("api_key", nil) end
function store.set_api_key(k) store.set("api_key", k) end
function store.clear_api_key() store.clear("api_key") end

function store.api_base()
  return store.get("api_base", "https://api.mirelo.ai")
end

return store
