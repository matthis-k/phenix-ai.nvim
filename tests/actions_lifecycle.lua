-- Exercise delayed UI/auth callbacks independently of transport timing.
local listeners, deferred = {}, {}
local active = {}
local auth_calls, selection_calls, resume_calls = 0, 0, 0
local prompt_callbacks = {}
local runtime = {
  on_event = function(listener) listeners[#listeners + 1] = listener end,
  active_session_object = function() return active end,
  active_session = function() return "session-send" end,
  activate_session = function() end,
  status = function()
    return { connection = "ready", session_id = "session-send" }
  end,
  session_state = function()
    return { sessions = {} }
  end,
  refresh_session_state = function() end,
  prompt = function(_, _, callback)
    table.insert(prompt_callbacks, callback)
  end,
  list_authentication_methods = function(callback)
    callback({ methods = { { id = "oauth", provider = "provider-a", kind = "oauth", name = "OAuth" } } })
  end,
  authenticate = function(_, _, callback)
    auth_calls = auth_calls + 1
    callback({ kind = "external", uri = "https://example.invalid/oauth" })
  end,
  list_selections = function(callback)
    callback({
      selected = "model.provider-a.model-a.high",
      available = {
        {
          id = "model.provider-a.model-a.high",
          provider = "provider-a",
          model = "model-a",
          thinking = "high",
          authenticated = true,
          presentation = "Model",
        },
      },
    })
  end,
  select = function(_, callback)
    selection_calls = selection_calls + 1
    callback({})
  end,
  list_sessions = function(callback)
    callback({ sessions = { { session_id = "session-a", title = "A" } } })
  end,
  resume_session = function(_, callback)
    resume_calls = resume_calls + 1
    callback({})
  end,
}
package.loaded["phenix_nvim.runtime"] = runtime
local picked, items
vim.ui.select = function(values, _, callback) items, picked = values, callback end
vim.ui.open = function() return {} end
vim.defer_fn = function(callback) deferred[#deferred + 1] = callback end
vim.notify = function() end
local actions = require("phenix_nvim.actions")
local function status(connection)
  for _, listener in ipairs(listeners) do listener("status", { connection = connection }) end
end

-- A delayed OAuth poll must not authenticate a replacement connection.
actions.authenticate()
picked(items[1])
assert(auth_calls == 1 and #deferred == 1)
status("disconnected")
status("connecting")
status("ready")
deferred[1]()
assert(auth_calls == 1, "stale OAuth poll reached replacement connection")

-- The authentication picker itself is also tied to its connection.
actions.authenticate()
status("failed")
status("connecting")
status("ready")
picked(items[1])
assert(auth_calls == 1, "stale authentication picker reached replacement connection")

-- A model picker is application-scoped, but a stale picker may not mutate a replacement connection.
actions.choose_selection()
local stale_model_items, stale_model_pick = items, picked
status("failed")
status("connecting")
status("ready")
stale_model_pick(stale_model_items[1])
assert(selection_calls == 0, "stale model picker reached replacement connection")

actions.choose_selection()
picked(items[1]) -- provider
picked(items[1]) -- model
picked(items[1]) -- thinking
assert(selection_calls == 1, "provider/model/thinking flow did not select the model")

-- Providers exposed only through Phenix auth discovery can authenticate first,
-- refresh their catalog, and continue through model/thinking selection.
local original_list_authentication_methods = runtime.list_authentication_methods
local original_authenticate = runtime.authenticate
local original_list_selections = runtime.list_selections
local util = require("phenix_nvim.util")
local original_input_secret = util.input_secret
local catalog_ready = false
runtime.list_authentication_methods = function(callback)
  callback({
    methods = {
      {
        id = "provider-b-token",
        provider = "provider-b",
        kind = "api_token",
        name = "API key",
      },
    },
  })
end
runtime.authenticate = function(method, secret, callback)
  assert(method == "provider-b-token")
  assert(secret == "provider-b-secret")
  catalog_ready = true
  callback({ kind = "authenticated" })
end
runtime.list_selections = function(callback)
  callback({
    selected = nil,
    available = catalog_ready and {
      {
        id = "model.provider-b.model-b.default",
        provider = "provider-b",
        model = "model-b",
        thinking = nil,
        authenticated = true,
        presentation = "Model",
      },
    } or {},
  })
end
util.input_secret = function(_, callback)
  callback("provider-b-secret", nil)
end

actions.choose_selection()
assert(items[1] == "provider-b", "auth-only provider was not offered by the model picker")
picked(items[1]) -- provider; authentication happens and the catalog is refreshed
picked(items[1]) -- model
picked(items[1]) -- default thinking
assert(selection_calls == 2, "authenticated provider did not continue into model selection")

runtime.list_authentication_methods = original_list_authentication_methods
runtime.authenticate = original_authenticate
runtime.list_selections = original_list_selections
util.input_secret = original_input_secret

-- A delayed session picker must not resume a session on a replacement connection.
local sessions = require("phenix_nvim.sessions")
sessions.choose()
local stale_items, stale_pick = items, picked
status("failed")
status("connecting")
status("ready")
stale_pick(stale_items[1])
assert(resume_calls == 0, "stale session picker reached replacement connection")
sessions.choose()
picked(items[1])
assert(resume_calls == 1)

-- Repeating send without editing must not dispatch the same compose revision twice.
local compose = require("phenix_nvim.compose.buffer")
local state = require("phenix_nvim.state")
local original_serialize = compose.serialize
local original_clear = compose.clear
local clear_calls = 0
compose.serialize = function()
  return { { kind = "text", text = "question" } }
end
compose.clear = function()
  clear_calls = clear_calls + 1
end
state.compose.revision = 100
actions.send()
actions.send()
assert(#prompt_callbacks == 1, "same compose revision was submitted more than once")
prompt_callbacks[1]({}, nil)
assert(clear_calls == 1)
actions.send()
assert(#prompt_callbacks == 2, "settled compose revision should be sendable again")
state.compose.revision = 101
actions.send()
assert(#prompt_callbacks == 3, "edited compose revision must remain independently sendable")
compose.serialize = original_serialize
compose.clear = original_clear

print("action lifecycle regressions passed")
