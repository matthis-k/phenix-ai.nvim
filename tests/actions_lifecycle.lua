-- Exercise delayed UI/auth callbacks independently of transport timing.
local listeners, deferred = {}, {}
local active = {}
local connection = "ready"
local auth_calls, selection_calls, resume_calls = 0, 0, 0
local prompt_callbacks = {}
local session_projections = {}
local runtime = {
  on_event = function(listener) listeners[#listeners + 1] = listener end,
  active_session_object = function() return active end,
  active_session = function() return "session-send" end,
  activate_session = function() end,
  status = function()
    return { connection = connection, session_id = "session-send" }
  end,
  session_state = function()
    return { sessions = session_projections }
  end,
  refresh_session_state = function() end,
  prompt = function(_, _, callback)
    table.insert(prompt_callbacks, callback)
  end,
  list_authentication_methods = function(callback)
    callback({ methods = { {
      id = "oauth",
      provider = "provider-a",
      provider_name = "Provider A",
      kind = "oauth",
      name = "OAuth",
      authenticated = true,
    } } })
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
        {
          id = "model.provider-a.model-a.low",
          provider = "provider-a",
          model = "model-a",
          thinking = "low",
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
local picked, items, select_options
vim.ui.select = function(values, options, callback)
  items, picked, select_options = values, callback, options
end
vim.ui.open = function() return {} end
vim.defer_fn = function(callback) deferred[#deferred + 1] = callback end
vim.notify = function() end
local actions = require("phenix_nvim.actions")
local util = require("phenix_nvim.util")
local function status(value)
  connection = value
  for _, listener in ipairs(listeners) do listener("status", { connection = value }) end
end

-- Authentication started before the first connection survives the normal
-- disconnected -> connecting -> ready transition.
status("disconnected")
actions.authenticate()
status("connecting")
status("ready")
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

-- A newer authentication picker supersedes an older picker on the same connection.
actions.authenticate()
local superseded_auth_items, superseded_auth_pick = items, picked
actions.authenticate()
superseded_auth_pick(superseded_auth_items[1])
assert(auth_calls == 1, "superseded authentication picker remained live")

-- A delayed API-key prompt must not authenticate a replacement connection.
local stale_auth_methods = runtime.list_authentication_methods
local stale_input_secret = util.input_secret
local secret_callback = nil
runtime.list_authentication_methods = function(callback)
  callback({ methods = { {
    id = "api-token",
    provider = "provider-a",
    provider_name = "Provider A",
    kind = "api_token",
    name = "API key",
  } } })
end
util.input_secret = function(_, callback)
  secret_callback = callback
end
actions.authenticate()
picked(items[1])
assert(secret_callback ~= nil, "API-key prompt was not opened")
status("failed")
status("connecting")
status("ready")
secret_callback("stale-secret", nil)
assert(auth_calls == 1, "stale API-key prompt reached replacement connection")
runtime.list_authentication_methods = stale_auth_methods
util.input_secret = stale_input_secret

-- A newer model picker supersedes an older picker on the same connection.
actions.choose_selection()
local superseded_model_items, superseded_model_pick = items, picked
actions.choose_selection()
superseded_model_pick(superseded_model_items[1])
assert(selection_calls == 0, "superseded model picker remained live")

-- A model picker is application-scoped, but a stale picker may not mutate a replacement connection.
actions.choose_selection()
local stale_model_items, stale_model_pick = items, picked
status("failed")
status("connecting")
status("ready")
stale_model_pick(stale_model_items[1])
assert(selection_calls == 0, "stale model picker reached replacement connection")

status("disconnected")
actions.choose_selection()
status("connecting")
status("ready")
assert(select_options.format_item(items[1]):find("Provider A", 1, true), "provider display name was not rendered")
picked(items[1]) -- provider
picked(items[1]) -- model
assert(#items == 2, "known thinking variants did not reach the thinking picker")
assert(select_options.prompt == "Thinking for model-a", "thinking picker prompt is incorrect")
picked(items[1]) -- thinking
assert(selection_calls == 1, "provider/model/thinking flow did not select the model")

-- Providers exposed only through Phenix auth discovery can authenticate first,
-- refresh their catalog, and continue through model/thinking selection.
local original_list_authentication_methods = runtime.list_authentication_methods
local original_authenticate = runtime.authenticate
local original_list_selections = runtime.list_selections
local original_input_secret = util.input_secret
local catalog_ready = false
runtime.list_authentication_methods = function(callback)
  callback({
    methods = {
      {
        id = "provider-b-token",
        provider = "provider-b",
        provider_name = "Provider B",
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
assert(select_options.format_item(items[1]):find("Provider B", 1, true), "auth-only provider name was not rendered")
picked(items[1]) -- provider; authentication happens and the catalog is refreshed
picked(items[1]) -- model; no unsupported thinking picker is shown
assert(selection_calls == 2, "authenticated provider did not continue into model selection")

runtime.list_authentication_methods = original_list_authentication_methods
runtime.authenticate = original_authenticate
runtime.list_selections = original_list_selections
util.input_secret = original_input_secret

-- A delayed session picker must not resume a session on a replacement connection.
local sessions = require("phenix_nvim.sessions")
sessions.choose()
local superseded_session_items, superseded_session_pick = items, picked
sessions.choose()
superseded_session_pick(superseded_session_items[1])
assert(resume_calls == 0, "superseded session picker remained live")
sessions.choose()
local stale_items, stale_pick = items, picked
status("failed")
status("connecting")
status("ready")
stale_pick(stale_items[1])
assert(resume_calls == 0, "stale session picker reached replacement connection")
status("disconnected")
sessions.choose()
status("connecting")
status("ready")
picked(items[1])
assert(resume_calls == 1)

-- A sent draft remains until its user message is in the transcript.
-- The model's final response does not control draft clearing.
local compose = require("phenix_nvim.compose.buffer")
local state = require("phenix_nvim.state")
local original_serialize = compose.serialize
local original_clear = compose.clear
local clear_calls = 0
local prompt_text = "question"
compose.serialize = function()
  return { { kind = "text", text = prompt_text } }
end
compose.clear = function()
  clear_calls = clear_calls + 1
end
state.compose.revision = 100
actions.send()
actions.send()
assert(#prompt_callbacks == 1, "same compose revision was submitted twice")
assert(clear_calls == 0, "draft cleared before the transcript accepted it")

session_projections["session-send"] = {
  session = { session_id = "session-send" },
  through_sequence = 1,
  updates = {
    {
      sequence = 1,
      update = {
        kind = "Message",
        message = {
          role = { kind = "User" },
          content = { { kind = "Text", text = "question" } },
        },
      },
    },
  },
}
for _, listener in ipairs(listeners) do
  listener("sessions", { sessions = session_projections })
end
assert(clear_calls == 1, "accepted user prompt must clear before final response")

-- A follow-up is queued in the per-chat pane while the earlier turn runs.
prompt_text = "follow-up"
actions.send()
assert(#prompt_callbacks == 1, "concurrent follow-up must stay in the local queue")
assert(clear_calls == 2, "queued draft must clear after entering the visible queue")
prompt_callbacks[1]({}, nil)
assert(clear_calls == 2, "final response must not clear an already accepted draft")
assert(#prompt_callbacks == 2, "settling the previous execution must dispatch queued follow-up")
session_projections["session-send"].through_sequence = 2
table.insert(session_projections["session-send"].updates, {
  sequence = 2,
  update = {
    kind = "Message",
    message = {
      role = { kind = "User" },
      content = { { kind = "Text", text = "follow-up" } },
    },
  },
})
for _, listener in ipairs(listeners) do
  listener("sessions", { sessions = session_projections })
end
assert(clear_calls == 2, "queued prompt was already removed from the composer")
prompt_callbacks[2]({}, nil)

-- A rejected unqueued prompt retains its compose draft and can be retried.
prompt_text = "rejected"
actions.send()
assert(#prompt_callbacks == 3)
prompt_callbacks[3](nil, { kind = "failed", message = "fixture model failure" })
assert(clear_calls == 2, "failed prompt without admission must preserve the draft")
actions.send()
assert(#prompt_callbacks == 4, "failed compose draft must be retryable")
session_projections["session-send"].through_sequence = 3
table.insert(session_projections["session-send"].updates, {
  sequence = 3,
  update = {
    kind = "Message",
    message = {
      role = { kind = "User" },
      content = { { kind = "Text", text = "rejected" } },
    },
  },
})
for _, listener in ipairs(listeners) do
  listener("sessions", { sessions = session_projections })
end
assert(clear_calls == 3, "retried prompt accepted in transcript must clear")
prompt_callbacks[4]({}, nil)

-- The user can queue a changed draft before the first prompt appears in the
-- session journal. Admission of the first prompt must preserve that later edit.
prompt_text = "before-admission"
state.compose.revision = 200
actions.send()
assert(#prompt_callbacks == 5)
prompt_text = "before-admission-follow-up"
state.compose.revision = 201
actions.send()
assert(#prompt_callbacks == 5, "pre-admission follow-up must queue, not dispatch concurrently")
assert(clear_calls == 4, "pre-admission queued draft must leave the composer")

session_projections["session-send"].through_sequence = 4
table.insert(session_projections["session-send"].updates, {
  sequence = 4,
  update = {
    kind = "Message",
    message = {
      role = { kind = "User" },
      content = { { kind = "Text", text = "before-admission" } },
    },
  },
})
for _, listener in ipairs(listeners) do
  listener("sessions", { sessions = session_projections })
end
assert(clear_calls == 4, "late admission must not clear a newer compose revision")
prompt_callbacks[5]({}, nil)
assert(#prompt_callbacks == 6, "settling admitted prompt must dispatch its queued follow-up")
session_projections["session-send"].through_sequence = 5
table.insert(session_projections["session-send"].updates, {
  sequence = 5,
  update = {
    kind = "Message",
    message = {
      role = { kind = "User" },
      content = { { kind = "Text", text = "before-admission-follow-up" } },
    },
  },
})
for _, listener in ipairs(listeners) do
  listener("sessions", { sessions = session_projections })
end
prompt_callbacks[6]({}, nil)

-- Disconnects must stop automatic dispatch and invalidate callbacks from the old
-- connection. A queued item remains recoverable until the user resumes it.
local queue_view = require("phenix_nvim.queue")
local original_queue_render = queue_view.render
local queued_snapshot, resume_queue
queue_view.render = function(_, entries, _, resume)
  queued_snapshot = vim.deepcopy(entries)
  resume_queue = resume
end
prompt_text = "in-flight-disconnect"
state.compose.revision = 300
actions.send()
assert(#prompt_callbacks == 7)
prompt_text = "queued-after-disconnect"
state.compose.revision = 301
actions.send()
assert(#prompt_callbacks == 7 and clear_calls == 5)
status("disconnected")
assert(queued_snapshot and #queued_snapshot == 1, "disconnect dropped a queued follow-up")
assert(queued_snapshot[1].content[1].text == "queued-after-disconnect")
status("connecting")
status("ready")
prompt_callbacks[7]({}, nil)
assert(#prompt_callbacks == 7, "old connection callback dispatched a new prompt")
assert(clear_calls == 5, "old connection callback cleared a newer draft")
assert(resume_queue ~= nil, "disconnected queue lost manual resume")
resume_queue()
assert(#prompt_callbacks == 8, "explicit resume must dispatch the preserved follow-up")
prompt_callbacks[8](nil, { kind = "disconnected" })
assert(queued_snapshot and #queued_snapshot == 1, "rejected queued follow-up must be recoverable")
queue_view.render = original_queue_render

-- A session opening must accept local queued follow-ups before an ID exists.
local sidebar = require("phenix_nvim.sidebar")
local original_current_surface = sidebar.current_surface
local original_new_session = runtime.new_session
local original_bind_session = sidebar.bind_session
local session_open_callback
local temporary_surface = { compose = state.compose }
sidebar.current_surface = function() return temporary_surface end
runtime.new_session = function(callback) session_open_callback = callback end
sidebar.bind_session = function(session_id, surface)
  surface.session_id = session_id
end

prompt_text = "before-session-exists"
state.compose.revision = 400
actions.send()
assert(session_open_callback ~= nil)
assert(#prompt_callbacks == 8, "no prompt may dispatch without a session ID")
prompt_text = "follow-up-before-session"
state.compose.revision = 401
actions.send()
assert(clear_calls == 6, "pre-session follow-up must be visible in its queue")
session_open_callback({ session_id = "created-session" }, nil)
assert(#prompt_callbacks == 9, "created session must send the original draft first")
prompt_callbacks[9]({}, nil)
assert(#prompt_callbacks == 10, "queued prompt must dispatch after first turn settles")
prompt_callbacks[10]({}, nil)

sidebar.current_surface = original_current_surface
runtime.new_session = original_new_session
sidebar.bind_session = original_bind_session

compose.serialize = original_serialize
compose.clear = original_clear

print("action lifecycle regressions passed")
