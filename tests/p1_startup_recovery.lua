-- Installed P1 ACP failure/retry contract. Use a missing executable first,
-- then recover with the real packaged Basic graph in the same Neovim process.
local binary = assert(vim.env.PHENIX_P1_BIN, "PHENIX_P1_BIN required")
local frontend = require("phenix_nvim")
local runtime = require("phenix_nvim.runtime")

frontend.setup({
  backend = "p1",
  command = "/nonexistent/phenix-p1-acp-missing",
  auto_connect = false,
})
local failed_connections, failed_requests = 0, 0
local startup_error, pending_error
frontend.connect(function(_, err)
  failed_connections = failed_connections + 1
  startup_error = err
end)
frontend.new_session(function(_, err)
  failed_requests = failed_requests + 1
  pending_error = err
end)
assert(vim.wait(10000, function()
  return failed_connections == 1 and failed_requests == 1
end, 15), "missing P1 executable did not settle both callbacks")
assert(startup_error and startup_error.kind == "transport", vim.inspect(startup_error))
assert(pending_error and pending_error.kind == "transport", vim.inspect(pending_error))
assert(runtime.status().connection == "failed")

-- Retrying is explicitly authorized by the editor; no legacy fallback or
-- hidden reconnect. Both callbacks belong to the replacement generation.
frontend.setup({ backend = "p1", command = binary, auto_connect = false })
local retried_connections, retried_requests = 0, 0
local retry_error, session_error, created
frontend.connect(function(value, err)
  retried_connections = retried_connections + 1
  retry_error = err
  assert(value ~= nil or err ~= nil)
end)
frontend.new_session(function(value, err)
  retried_requests = retried_requests + 1
  session_error, created = err, value
end)
assert(vim.wait(30000, function()
  return retried_connections > 0 and retried_requests > 0
end, 15), "P1 Basic retry did not settle both callbacks")
assert(retried_connections == 1 and retried_requests == 1,
  "P1 retry callbacks must settle exactly once")
assert(not retry_error and not session_error, vim.inspect(retry_error or session_error))
assert(created and type(created.session_id) == "string" and created.session_id ~= "")
assert(runtime.status().connection == "ready")
assert(runtime.active_session() == created.session_id)
assert(failed_connections == 1 and failed_requests == 1,
  "old failed-generation callbacks were resurrected after reconnect")
frontend.disconnect()
print("Installed P1 failed launch and explicit real-Basic recovery passed")
