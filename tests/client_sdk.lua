-- The Lua API is a client. Permissions and state remain in Phenix.
local sdk = require("phenix_client")
local calls, listeners = {}, {}
local backend = {
  start = function(self, cb)
    cb({ session_operations = { new = true, load = true, send = true, cancel = true },
      management = { models = true, model_selection = true } })
  end,
  call = function(self, op, args, cb)
    calls[#calls + 1] = { op = op, args = args }
    if op == "models.list" then
      cb({ revision = 7, models = {
        { id = "provider/a", name = "A", authorized = true },
      } })
    elseif op == "models.select" then
      cb({ revision = 8, selected = args.model_id })
    elseif op == "sessions.new" then
      cb({ session_id = "s1" })
    elseif op == "sessions.send" then
      cb({ stop_reason = "end_turn" })
    else
      cb(nil, { kind = "unsupported", message = op })
    end
  end,
  subscribe = function(self, callback)
    listeners[#listeners + 1] = callback
    return function() listeners[1] = nil end
  end,
  close = function() end,
}
local client = sdk.new(backend)
local events = {}
local stop = client:on("model.changed", function(event)
  events[#events + 1] = event
end)
client:start(function(value, err)
  assert(not err and value.management.models)
end)
local models
client:list_models(function(value, err)
  assert(not err)
  models = value
end)
assert(models.revision == 7)
assert(models.models[1].name == "A")
client:set_model("provider/a", function(value, err)
  assert(not err and value.selected == "provider/a")
end)
assert(calls[2].op == "models.select")
assert(calls[2].args.model_id == "provider/a")
listeners[1]({ type = "model.changed", model_id = "provider/a", revision = 8 })
assert(#events == 1 and events[1].revision == 8)
stop()
listeners[1]({ type = "model.changed", revision = 9 })
assert(#events == 1, "removed UI listener must not receive events")
client:new_session(function(value, err)
  assert(not err and value.session_id == "s1")
end)
client:send("s1", "hello", function(value, err)
  assert(not err and value.stop_reason == "end_turn")
end)
assert(calls[4].op == "sessions.send")
assert(calls[4].args.text == "hello")
assert(calls[4].args.session_id == "s1")
client:close()

local restricted_calls = 0
local restricted = sdk.new({
  start = function(_, cb)
    cb({ session_operations = { new = true, send = true },
      management = { models = false, model_selection = false } })
  end,
  call = function()
    restricted_calls = restricted_calls + 1
  end,
  subscribe = function() return function() end end,
  close = function() end,
})
restricted:start()
restricted:list_models(function(value, err)
  assert(value == nil and err.kind == "unsupported")
end)
restricted:set_model("provider/a", function(value, err)
  assert(value == nil and err.kind == "unsupported")
end)
assert(restricted_calls == 0)
print("Lua client SDK capability and authority delegation passed")
