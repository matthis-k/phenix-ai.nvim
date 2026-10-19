-- No executable or transport is needed: exercise callbacks delivered after a
-- client is retired, then verify the replacement generation is untouched.
local clients = {}
local function fake_client()
  local self = { events = {}, closed = false }
  function self:on(name, callback) self.events[name] = callback end
  function self:start(callback) callback({}, nil) end
  function self:close() self.closed = true end
  function self:new_session(callback) self.new_reply = callback end
  function self:load_session(_, callback) self.load_reply = callback end
  function self:send_content(_, _, callback) self.send_reply = callback end
  function self:capabilities()
    return { session_operations = {}, management = { models = true } }
  end
  function self:list_models(_, callback)
    self.models_replies = self.models_replies or {}
    table.insert(self.models_replies, callback)
  end
  clients[#clients + 1] = self
  return self
end

package.loaded["phenix_client"] = { new = function() return fake_client() end }
package.loaded["phenix_client.acp"] = { new = function(options)
  assert(options.command == "fake-acp")
  return {}
end }
local model_reply
package.loaded["phenix_client.nvim"] = { choose_model = function(_, _, callback)
  model_reply = callback
end }

local runtime = require("phenix_nvim.runtime_p1")
runtime.configure({ backend = "p1", command = "fake-acp" })
local function assert_retired(result, problem)
  assert(result == nil and problem and problem.kind == "disconnected",
    "retired ACP reply must report disconnected, not accept stale state")
end
local function assert_empty()
  assert(runtime.active_session() == nil, "retired callback changed active session")
  runtime.list_sessions(function(result, err)
    assert(not err and #result.sessions == 0,
      "retired callback inserted a session into the new generation")
  end)
end

-- A delayed session/new reply must not become the new connection's session.
local old_created = 0
runtime.new_session(function(value, err)
  old_created = old_created + 1
  assert_retired(value, err)
end)
local first = assert(clients[1])
assert(type(first.new_reply) == "function")
runtime.disconnect()
runtime.connect()
local second = assert(clients[2])
first.new_reply({ session_id = "retired-new" }, nil)
assert(first.closed and old_created == 1)
assert_empty()

-- A delayed session/load success must neither resurrect journal projection
-- nor replace the new connection's active session.
local old_loaded = 0
runtime.resume_session("retired-load", function(value, err)
  old_loaded = old_loaded + 1
  assert_retired(value, err)
end)
assert(type(second.load_reply) == "function")
runtime.disconnect()
runtime.connect()
local third = assert(clients[3])
second.load_reply({ session_id = "retired-load" }, nil)
assert(second.closed and old_loaded == 1)
assert_empty()
assert(runtime.session_state().sessions["retired-load"] == nil)

-- A legitimate reply on the current generation must still work.
local created
runtime.new_session(function(value, err)
  assert(not err)
  created = value.session_id
end)
third.new_reply({ session_id = "current" }, nil)
assert(created == "current" and runtime.active_session() == "current")

-- Pending prompts and model displays must report disconnection rather than
-- accepting a successful response from the previously installed client.
local old_prompt, old_catalog, old_selection, old_picker = 0, 0, 0, 0
runtime.prompt("current", { { kind = "text", text = "hello" } }, function(value, err)
  old_prompt = old_prompt + 1
  assert_retired(value, err)
end)
runtime.capabilities(function(value, err)
  old_catalog = old_catalog + 1
  assert_retired(value, err)
end)
runtime.list_selections(function(value, err)
  old_selection = old_selection + 1
  assert_retired(value, err)
end)
runtime.choose_model(function(value, err)
  old_picker = old_picker + 1
  assert_retired(value, err)
end)
assert(third.send_reply and third.models_replies and #third.models_replies == 2 and model_reply)
runtime.disconnect()
runtime.connect()
local fourth = assert(clients[4])
third.send_reply({ stop_reason = "end_turn" }, nil)
third.models_replies[1]({ selected = "old-model", models = {} }, nil)
third.models_replies[2]({ selected = "old-model", models = {} }, nil)
model_reply({ selected = "old-model" }, nil)
assert(old_prompt == 1 and old_catalog == 1 and old_selection == 1 and old_picker == 1)
assert_empty()

local fresh
runtime.new_session(function(value, err)
  assert(not err)
  fresh = value.session_id
end)
fourth.new_reply({ session_id = "fresh" }, nil)
assert(fresh == "fresh" and runtime.active_session() == "fresh",
  "replacement P1 connection must still admit its own operations")
runtime.disconnect()
print("P1 retired operation callbacks cannot mutate replacement session state")
