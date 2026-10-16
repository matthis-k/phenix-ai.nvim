-- Real P1 product acceptance through the existing Neovim chat UI.
-- Uses no legacy native Lua module, fake model provider or second UI.
local binary = assert(vim.env.PHENIX_P1_BIN, "PHENIX_P1_BIN is required")
local front = require("phenix_nvim")
local runtime = require("phenix_nvim.runtime")
local compose = require("phenix_nvim.compose.buffer")
local sidebar = require("phenix_nvim.sidebar")
local model = require("phenix_nvim.transcript.model")

front.setup({ backend = "p1", command = binary, auto_connect = false })
local surface = assert(front.new("sidebar"))
assert(surface.compose and surface.transcript_key)
local buffer = compose.ensure(surface.compose)
vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { "hello" })
front.send()

local function contains_output()
  local id = surface.session_id
  if not id then return false end
  local projection = runtime.session_state().sessions[id]
  if not projection then return false end
  local rendered = model.rebuild(projection)
  if not rendered then return false end
  local user, assistant = false, false
  for _, node_id in ipairs(rendered.order) do
    local node = rendered.nodes[node_id]
    if node.role == "user" and node.text == "hello" then user = true end
    if node.role == "assistant" and node.text == "mock:hello" then assistant = true end
  end
  return user and assistant
end
assert(vim.wait(30000, contains_output, 20),
  "Existing rich UI did not render the P1 model response and user prompt")
-- Exercise a second turn through the same real compose buffer and runtime
-- session. A one-turn success must not mask broken P1 tool rendering.
assert(vim.wait(10000, function()
  local lines = vim.api.nvim_buf_get_lines(buffer, 0, -1, false)
  return #lines == 1 and lines[1] == ""
end, 20), "P1 compose did not clear the completed first submission")
vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { "tools:hello" })
front.send()
local function contains_tool_turn()
  local id = surface.session_id
  local projection = id and runtime.session_state().sessions[id]
  if not projection then return false end
  local rendered = model.rebuild(projection)
  if not rendered then return false end
  local user, answer, tools = false, false, 0
  for _, node_id in ipairs(rendered.order) do
    local node = rendered.nodes[node_id]
    if node.role == "user" and node.text == "tools:hello" then user = true end
    if node.role == "assistant" and node.text == "mock:call-1:HELLO|call-2:5" then
      answer = true
    end
    if node.kind == "tool" then tools = tools + 1 end
  end
  return user and answer and tools == 2
end
assert(vim.wait(30000, contains_tool_turn, 20),
  "P1 rich UI did not render the second turn and two tool calls")
local session_id = assert(surface.session_id)
assert(runtime.active_session() == session_id)
local current = runtime.session_state().sessions[session_id]
assert(current and current.through_sequence > 1)

-- The model picker queries the runtime-owned catalog.
local original = vim.ui.select
local seen = false
vim.ui.select = function(options, config, callback)
  assert(config.prompt == "Phenix model")
  assert(#options == 1 and options[1].id == "phenix.model.scripted")
  seen = true
  callback(options[1])
end
front.choose_selection()
assert(vim.wait(10000, function() return seen end, 20),
  "Existing selection command did not query P1 model options")
vim.ui.select = original

front.disconnect()
assert(runtime.status().connection == "disconnected")
local reloaded, reload_error
runtime.resume_session(session_id, function(value, err)
  reloaded, reload_error = value, err
end)
assert(vim.wait(30000, function() return reloaded ~= nil or reload_error ~= nil end, 20),
  "Existing Neovim runtime could not reload the durable P1 session")
assert(not reload_error and reloaded.session_id == session_id)
assert(runtime.active_session() == session_id)
assert(contains_output(), "P1 restart replay did not restore both transcript speakers")
assert(contains_tool_turn(), "P1 restart replay lost the second turn or tool events")
sidebar.bind_session(session_id, surface)
assert(vim.wait(5000, function()
  local rendered = require("phenix_nvim.transcript.controller").projection(surface.transcript_key)
  return rendered and rendered.session_id == session_id and #rendered.order > 1
end, 20), "Existing transcript window did not resync after P1 replay")
front.disconnect()
print("Existing rich Neovim UI -> P1 ACP -> rich transcript -> reload passed")
