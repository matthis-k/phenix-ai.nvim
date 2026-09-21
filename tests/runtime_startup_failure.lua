local frontend = require("phenix_nvim")
local runtime = require("phenix_nvim.runtime")
frontend.setup({
  auto_connect = false,
  command = "sh",
  args = { "-c", "printf 'PHENIX_STARTUP_FAILURE_MARKER\\n' >&2; exit 1" },
})
local connections, requests = 0, 0
local connection_error, request_error
frontend.connect(function(_, err)
  connections = connections + 1
  connection_error = err
end)
frontend.new_session(function(_, err)
  requests = requests + 1
  request_error = err
end)
assert(vim.wait(10000, function() return connections == 1 and requests == 1 end, 10),
  "crashed runtime must settle both connection and early session requests")
assert(connection_error ~= nil and request_error ~= nil)
assert(connection_error.kind == "transport", vim.inspect(connection_error))
assert(connection_error.message:find("PHENIX_STARTUP_FAILURE_MARKER", 1, true), vim.inspect(connection_error))
assert(vim.deep_equal(request_error, connection_error))
assert(runtime.status().connection == "failed")

frontend.setup({ auto_connect = false, command = assert(vim.env.PHENIX_FIXTURE_ACP), args = {}, selection = false })
local reconnected, created, retry_error
frontend.connect(function(_, err)
  reconnected, retry_error = true, err
end)
frontend.new_session(function(value, err)
  created, retry_error = value, err
end)
assert(vim.wait(10000, function() return retry_error ~= nil or (reconnected and created ~= nil) end, 10),
  "explicit reconnect after startup failure must recover")
assert(retry_error == nil, vim.inspect(retry_error))
assert(created.session_id == runtime.active_session())
assert(connections == 1 and requests == 1, "old callbacks must not run after reconnect")
frontend.disconnect()
print("native startup failure and reconnect passed")
