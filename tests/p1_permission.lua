-- Permission decisions must be explicit, scoped and encoded as ACP v1 replies.
local sent, process = {}, nil
vim.fn.jobstart = function(_, opts) process = opts; return 101 end
vim.fn.chansend = function(_, payload)
  sent[#sent + 1] = vim.json.decode(payload)
  return #payload
end
vim.fn.jobstop = function() return 1 end

local Client = require("phenix_client")
local backend = require("phenix_client.acp").new({ command = "phenix-basic-acp" })
local client = Client.new(backend)
local function receive(frame)
  process.on_stdout(101, { vim.json.encode(frame), "" })
end
local caps
client:start(function(value, err) assert(not err); caps = value end)
receive({ jsonrpc = "2.0", id = 1, result = {
  protocolVersion = 1, agentCapabilities = { loadSession = true },
} })
assert(caps ~= nil)
local session_id
client:new_session(function(value, err)
  assert(not err)
  session_id = value.session_id
end)
receive({ jsonrpc = "2.0", id = 2, result = { sessionId = "s1" } })
assert(session_id == "s1")
local permission
client:on("permission.requested", function(event)
  permission = event
end)
local options = {
  { optionId = "allow", name = "Allow once", kind = "allow_once" },
  { optionId = "deny", name = "Deny", kind = "reject_once" },
}
local function ask(id)
  receive({ jsonrpc = "2.0", id = id, method = "session/request_permission",
    params = { sessionId = "s1",
      toolCall = { toolCallId = "tc1", title = "Run git" },
      options = options,
    } })
end
ask(20)
assert(permission.request_id == 20 and permission.session_id == "s1")
assert(permission.tool_call.title == "Run git")
assert(permission.options[2].optionId == "deny")
local rejected
client:respond_permission(20, "forged-option", function(_, err) rejected = err end)
assert(rejected and rejected.kind == "denied")
assert(#sent == 2, "forged response must not reach Phenix")
client:respond_permission(20, "deny", function(value, err)
  assert(value and not err)
end)
assert(sent[3].id == 20 and sent[3].result.outcome.outcome == "selected")
assert(sent[3].result.outcome.optionId == "deny")
client:respond_permission(20, "allow", function(_, err) rejected = err end)
assert(rejected and rejected.kind == "not_found")
assert(#sent == 3)

-- Cancelling the turn must cancel outstanding permission requests first.
ask(21)
client:cancel("s1")
assert(sent[4].id == 21 and sent[4].result.outcome.outcome == "cancelled")
assert(sent[5].method == "session/cancel" and sent[5].params.sessionId == "s1")

-- Client cancellation from a permission dialog sends the same ACP outcome.
ask(22)
client:respond_permission(22, nil)
assert(sent[6].id == 22 and sent[6].result.outcome.outcome == "cancelled")

-- A permission request with no UI subscriber must fail closed.
client:on("permission.requested", function() end)() -- remove a temporary listener
-- Above retained listener is needed for later UI; remove it using isolated SDK.
local other = Client.new({
  start = function(_, cb) cb({ session_operations = {} }) end,
  call = function(_, op, args, cb)
    assert(op == "permissions.respond")
    assert(args.request_id == 99 and args.option_id == nil)
    cb(true)
  end,
  subscribe = function(self, listener) self.listener = listener; return function() end end,
  close = function() end,
})
other:start()
other.backend.listener({
  type = "permission.requested", request_id = 99, session_id = "s99",
  options = { { optionId = "allow" } },
})
other:close()

-- A crashing Neovim UI handler must also fail closed.
local crash_answer
local crash = Client.new({
  start = function(_, cb) cb({ session_operations = {} }) end,
  call = function(_, op, args, cb)
    crash_answer = { op = op, args = args }
    cb(true)
  end,
  subscribe = function(self, listener) self.listener = listener; return function() end end,
  close = function() end,
})
crash:start()
crash:on("permission.requested", function() error("dialog crashed") end)
crash.backend.listener({
  type = "permission.requested", request_id = 100, session_id = "s100",
  options = { { optionId = "allow" } },
})
assert(crash_answer and crash_answer.op == "permissions.respond"
  and crash_answer.args.option_id == nil)
crash:close()
client:close()

local interaction = require("phenix_nvim.interaction")
local previous = vim.ui.select
local returned
vim.ui.select = function(items, config, cb)
  assert(config.prompt:find("Run git", 1, true))
  assert(items[1].name == "Allow once" and items[2].name == "Deny")
  cb(items[2])
end
interaction.acp_permission({
  tool_call = { title = "Run git" }, options = options,
}, function(option_id) returned = option_id end)
assert(returned == "deny")
vim.ui.select = function(_, _, cb) cb(nil) end
interaction.acp_permission({
  tool_call = { title = "Run git" }, options = options,
}, function(option_id) returned = option_id or "cancelled" end)
assert(returned == "cancelled")
vim.ui.select = previous
print("P1 ACP permissions require selected authorized option or cancellation")
