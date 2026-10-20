-- N5b editor controller: exact surface, binding and connection generations.
-- This is a real Neovim sidebar and compose buffer with a deterministic
-- request transport. Runtime admission remains authoritative and unmocked
-- by the production client: no queue dispatch or automatic replay is added.
local listeners = {}
local connection = "ready"
local sent = {}
local created_callback
local runtime = {
  on_event = function(listener) listeners[#listeners + 1] = listener end,
  status = function() return { connection = connection, session_id = "session-one" } end,
  active_session = function() return "session-one" end,
  activate_session = function() end,
  session_state = function() return { sessions = {} } end,
  refresh_session_state = function() end,
  p1_active = function() return false end,
  prompt = function(session_id, content, callback)
    sent[#sent + 1] = { session_id = session_id, content = content, finish = callback }
  end,
  new_session = function(callback) created_callback = callback end,
}
package.loaded["phenix_nvim.runtime"] = runtime
vim.notify = function() end

local actions = require("phenix_nvim.actions")
local sidebar = require("phenix_nvim.sidebar")
local compose = require("phenix_nvim.compose.buffer")
local state = require("phenix_nvim.state")
local clear_count = 0

compose.serialize = function()
  return { { kind = "text", text = "question" } }
end
compose.clear = function()
  clear_count = clear_count + 1
end

local function status(value)
  connection = value
  for _, listener in ipairs(listeners) do
    listener("status", { connection = value })
  end
end

local surface = assert(sidebar.open())
assert(surface.session_id == "session-one")
assert(surface.compose == state.compose)

-- A second send of an in-flight revision cannot issue a duplicate prompt.
state.compose.revision = 1
actions.send()
actions.send()
assert(#sent == 1 and sent[1].session_id == "session-one")
sent[1].finish({}, nil)
assert(clear_count == 1, "confirmed unchanged composer was not cleared")

-- Rebinding while the old prompt is running must not keep a draft hostage,
-- clear it on old completion, or misroute a subsequent submission.
state.compose.revision = 2
actions.send()
assert(#sent == 2)
sidebar.bind_session("session-two", surface)
actions.send()
assert(#sent == 3 and sent[3].session_id == "session-two",
  "old-session request blocked new-session composer")
sent[2].finish({}, nil)
assert(clear_count == 1, "old session cleared rebound compose document")
sent[3].finish({}, nil)
assert(clear_count == 2)

-- Transport replacement drops only editor callback authority: Phenix decides
-- whether the request completed and whether an explicit retry is appropriate.
state.compose.revision = 3
actions.send()
assert(#sent == 4)
status("failed")
status("connecting")
status("ready")
actions.send()
assert(#sent == 5)
sent[4].finish({}, nil)
assert(clear_count == 2, "stale transport callback cleared composer")
sent[5].finish({}, nil)
assert(clear_count == 3)

-- A -> B -> A returns to the same ID but a different binding generation.
state.compose.revision = 4
actions.send()
assert(#sent == 6)
sidebar.bind_session("session-intermediate", surface)
sidebar.bind_session("session-two", surface)
actions.send()
assert(#sent == 7, "A-B-A switch held the composer")
sent[6].finish({}, nil)
assert(clear_count == 3, "A-B-A resurrected the old callback")
sent[7].finish({}, nil)
assert(clear_count == 4)

-- Closing the window invalidates pending UI callbacks.
state.compose.revision = 5
actions.send()
assert(#sent == 8)
sidebar.close()
sent[8].finish({}, nil)
assert(clear_count == 4, "closed surface was mutated by late completion")

-- A new-session completion must not steal a surface rebound by the user.
local fresh = assert(sidebar.new("sidebar"))
assert(fresh.session_id == nil, "new surface should initially be unbound")
actions.send()
assert(created_callback ~= nil, "expected runtime-backed session creation")
sidebar.bind_session("session-manual", fresh)
created_callback({ session_id = "stale-created-session" }, nil)
assert(fresh.session_id == "session-manual", "stale creation changed surface binding")
assert(#sent == 8, "stale session creation dispatched a prompt")

print("N5 compose and surface lifecycle regressions passed")
