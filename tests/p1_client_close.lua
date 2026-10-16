-- Closing a transport settles in-flight client operations exactly once.
-- A late backend completion must not resurrect a retired client generation.
local Client = require("phenix_client")
local pending, messages = {}, {}
local backend = {
  start = function(_, callback) callback({
    session_operations = { new = true, load = true, send = true, cancel = true },
    management = { models = true, model_selection = false },
  }) end,
  call = function(_, op, _, callback)
    pending[op] = callback
  end,
  subscribe = function(self, callback)
    self.listener = callback
    return function() self.listener = nil end
  end,
  close = function(self) self.closed = true end,
}
local client = Client.new(backend)
client:start(function(value, err) assert(value and not err) end)
client:send("s1", "hello", function(result, err)
  messages[#messages + 1] = { kind = "send", result = result, error = err }
end)
client:list_models("s1", function(result, err)
  messages[#messages + 1] = { kind = "models", result = result, error = err }
end)
assert(#messages == 0)
client:close()
assert(backend.closed)
assert(#messages == 2, "all pending calls must settle when client closes")
for _, response in ipairs(messages) do
  assert(response.result == nil)
  assert(response.error.kind == "disconnected")
end
pending["sessions.send"]({ stop_reason = "end_turn" })
pending["models.list"]({ selected = "unexpected" })
assert(#messages == 2, "late replies must not complete a callback twice")
client:close()
assert(#messages == 2, "repeated close is idempotent")

-- An unsolicited transport failure revokes the SDK's connection state.
local other = Client.new({
  start = backend.start, call = backend.call, subscribe = backend.subscribe,
  close = backend.close,
})
other:start()
local observed
other:send("s1", "work", function(_, err) observed = err end)
other.backend.listener({ type = "connection.failed", error = {
  kind = "transport", message = "process exited",
} })
assert(observed and observed.kind == "transport")
assert(other:capabilities() == nil, "transport failure must revoke cached capabilities")
local second
other:send("s1", "cannot send", function(_, err) second = err end)
assert(second and second.kind == "disconnected")
other:close()
print("P1 client disconnect and in-flight settlement regressions passed")
