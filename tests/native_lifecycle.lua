local native = require("phenix")
local command = require("phenix_nvim.config").get().command
local uv = vim.uv or vim.loop
local pid_file = vim.fn.tempname()
local client = native.application.connect({
  command = "sh",
  args = { "-c", 'echo $$ > "$PHENIX_TEST_PID"; exec "$PHENIX_TEST_ACP"' },
  env = { PHENIX_TEST_PID = pid_file, PHENIX_TEST_ACP = command },
})
local function await(request)
  local done, value, err
  assert(vim.wait(10000, function()
    client:pump(64)
    done, value, err = request:poll()
    return done
  end, 10), "native request timed out")
  assert(err == nil, vim.inspect(err))
  return value
end
assert(vim.wait(10000, function()
  client:pump(64)
  return client:status().state == "ready"
end, 10), "native readiness timed out")
local pid = assert(tonumber(vim.fn.readfile(pid_file)[1]))
local sessions = client:sessions()
local session = await(sessions:create({ working_directory = vim.fn.getcwd() }))
local id = session:id()
assert(sessions:cached(id) ~= nil)
await(session:close())
assert(sessions:cached(id) == nil, "closed session remains in native cache")
client:pump(64)
assert(sessions:cached(id) == nil, "late event recreated a closed session")
local interrupted = sessions:list()
client:close()
local done, _, err = interrupted:poll()
assert(done and err ~= nil, "request pending at close must settle with an error")
client:close()
client:pump(64)
assert(client:status().state == "closed", "pump changed a closed client to another phase")
assert(vim.wait(2000, function() return uv.kill(pid, 0) == nil end, 10),
  "close left the owned ACP process alive while session handles were retained")
vim.fn.delete(pid_file)

-- Closing before bootstrap must also terminate the worker and remain closed.
for _ = 1, 10 do
  local connecting = native.application.connect({ command = command })
  connecting:close()
  connecting:pump(64)
  assert(connecting:status().state == "closed")
end
print("native close and session cache regressions passed")
