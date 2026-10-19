-- Contract test for the old rich UI facade running on the P1 Lua client.
-- Set up a fake transport with authoritative server-side events, not a fake UI.
local responses, listeners = {}, {}
local calls = {}
package.loaded["phenix_client.acp"] = {
  new = function()
    return {
      start = function(_, cb)
        cb({ session_operations = { new = true, load = true, send = true, cancel = true },
          management = { models = true, model_selection = false } })
      end,
      call = function(_, method, params, cb)
        calls[#calls + 1] = { method = method, params = params }
        if method == "sessions.new" then
          cb({ session_id = "p1-session" })
        elseif method == "sessions.load" then
          for _, listener in ipairs(listeners) do
            listener({ type = "session.updated", session_id = params.session_id,
              update = { sessionUpdate = "user_message_chunk",
                messageId = "replayed:user",
                content = { type = "text", text = "previous" } } })
          end
          cb({ session_id = params.session_id })
        elseif method == "sessions.send" then
          for _, listener in ipairs(listeners) do
            listener({ type = "session.updated", session_id = params.session_id, update = {
              sessionUpdate = "user_message_chunk",
              messageId = "run-1:user", content = { type = "text", text = params.content[1].text },
            } })
            listener({ type = "session.updated", session_id = params.session_id, update = {
              sessionUpdate = "agent_message_chunk",
              messageId = "run-1", content = { type = "text", text = "mock:hello" },
            } })
          end
          cb({ stop_reason = "end_turn" })
        elseif method == "permissions.respond" then
          cb({ selected = params.option_id })
        elseif method == "models.list" then
          cb({ session_id = params.session_id, selected = "scripted", models = {
            { id = "scripted", name = "Scripted" },
          } })
        else
          cb(nil, { kind = "unsupported", message = method })
        end
      end,
      subscribe = function(_, callback)
        listeners[#listeners + 1] = callback
        return function() end
      end,
      close = function() end,
    }
  end,
}
local runtime = require("phenix_nvim.runtime")
runtime.configure({ backend = "p1", command = "phenix-basic-acp", args = {} })
local observed = {}
runtime.on_event(function(kind) observed[#observed + 1] = kind end)
local connected, conn_error
runtime.connect(function(value, err) connected, conn_error = value, err end)
assert(not conn_error and connected)
assert(runtime.status().connection == "ready")
local session
runtime.new_session(function(value, err)
  assert(not err)
  session = value.session_id
end)
assert(session == "p1-session" and runtime.active_session() == session)
local done, prompt_error
runtime.prompt(session, { { kind = "text", text = "hello" } }, function(value, err)
  done, prompt_error = value, err
end)
assert(done and not prompt_error)
assert(calls[2].method == "sessions.send")
local snapshot = runtime.session_state().sessions[session]
assert(snapshot and snapshot.through_sequence == 2)
local model = require("phenix_nvim.transcript.model")
local rendered, err = model.rebuild(snapshot)
assert(rendered and not err)
local messages = {}
for _, id in ipairs(rendered.order) do
  local node = rendered.nodes[id]
  if node.kind == "message" then messages[#messages + 1] = node end
end
assert(#messages == 2 and messages[1].role == "user")
assert(messages[1].text == "hello")
assert(messages[2].role == "assistant" and messages[2].text == "mock:hello")
assert(vim.tbl_contains(observed, "sessions"))
local resumed
runtime.resume_session("durable-other-session", function(value, err)
  assert(not err)
  resumed = value.session_id
end)
assert(resumed == "durable-other-session")
assert(runtime.active_session() == resumed)
assert(runtime.session_state().sessions[resumed].through_sequence == 1)
local selection
runtime.list_selections(function(value, e)
  assert(not e)
  selection = value
end)
assert(selection and #selection.available == 1)
local advertised, capability_error
runtime.capabilities(function(value, err)
  advertised, capability_error = value, err
end)
assert(not capability_error and advertised.backend == "p1")
assert(advertised.transport == "acp-v1")
assert(advertised.session_operations.send == true)
assert(advertised.management.model_selection == false)
assert(advertised.selected_model == "scripted")
-- A runtime catalog update must reach the Neovim projection even when it
-- removes a previously shown choice. No client-local selection is committed.
for _, listener in ipairs(listeners) do
  listener({ type = "models.changed", session_id = resumed, catalog = nil })
end
assert(vim.tbl_contains(observed, "models"),
  "runtime model revocation must notify Neovim observers")
local unsupported
runtime.select("scripted", function(_, e) unsupported = e end)
assert(unsupported and unsupported.kind == "unsupported")
runtime.list_authentication_methods(function(_, e) unsupported = e end)
assert(unsupported and unsupported.kind == "unsupported")
-- User decisions from the existing Neovim permission dialog go only
-- through the authorized Phenix RPC response, never a local allow rule.
local old_select = vim.ui.select
local permission_rendered = false
vim.ui.select = function(options, details, done)
  assert(details.prompt:find("Delete branch", 1, true))
  assert(#options == 2 and options[2].optionId == "deny")
  permission_rendered = true
  done(options[2])
end
for _, listener in ipairs(listeners) do
  listener({
    type = "permission.requested", request_id = 77, session_id = resumed,
    tool_call = { title = "Delete branch" },
    options = {
      { optionId = "allow", name = "Allow once", kind = "allow_once" },
      { optionId = "deny", name = "Deny", kind = "reject_once" },
    },
  })
end
assert(vim.wait(2000, function() return permission_rendered end, 10),
  "The existing Neovim frontend must render runtime permission options")
local last = calls[#calls]
assert(last.method == "permissions.respond")
assert(last.params.request_id == 77 and last.params.option_id == "deny")
vim.ui.select = old_select

for _, listener in ipairs(listeners) do
  listener({ type = "connection.failed",
    error = { kind = "transport", message = "ACP process exited" } })
end
assert(runtime.status().connection == "failed",
  "A dead P1 process must not leave Neovim claiming it is ready")

-- A retry registered after failure must not be flushed by retiring the
-- previous generation. It must settle once against the *new* ACP connection.
local retry_callbacks, retry_value, retry_error = 0, nil, nil
runtime.connect(function(value, err)
  retry_callbacks = retry_callbacks + 1
  retry_value, retry_error = value, err
end)
assert(retry_callbacks == 1, "P1 reconnect callback must settle exactly once")
assert(retry_value ~= nil and retry_error == nil,
  "P1 reconnect must not fail because the previous generation was disconnected")
assert(runtime.status().connection == "ready",
  "P1 reconnect must restore ready state")

runtime.disconnect()
assert(runtime.status().connection == "disconnected")
print("P1 runtime facade and legacy transcript integration passed")
