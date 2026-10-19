local function completed(value)
  return { poll = function() return true, value, nil end }
end

local client = {
  events = {},
  registrations = {},
  removals = {},
  prompt_calls = 0,
}

local session = {
  id = function() return "session.tools" end,
  info = function() return { session_id = "session.tools", working_directory = vim.fn.getcwd() } end,
  projection = function() return nil end,
  status = function() return {} end,
}
function session.prompt()
  client.prompt_calls = client.prompt_calls + 1
  assert(#client.registrations == 7, "prompt ran before all Neovim tools were admitted")
  return completed({ execution_id = "execution.tools" })
end

client.sessions_api = {
  create = function() return completed(session) end,
  cached = function() return session end,
}
function client:sessions() return self.sessions_api end
function client:status() return { state = self.phase or "connecting" } end
function client:features() return {} end
function client:pump()
  local events = self.events
  self.events = {}
  return events
end
function client:close() end
function client:tools()
  return {
    register = function(definition, handler)
      table.insert(client.registrations, {
        definition = vim.deepcopy(definition),
        handler = handler,
      })
      local id = definition.id
      return completed(function()
        table.insert(client.removals, id)
        return completed({})
      end)
    end,
  }
end
function client:ready()
  self.phase = "ready"
  table.insert(self.events, { kind = "status", data = { state = "ready" } })
end

package.loaded.phenix = {
  application = {
    connect = function() return client end,
  },
}

local config = require("phenix_nvim.config")
local runtime = require("phenix_nvim.runtime")
local tools = require("phenix_nvim.tools")

runtime.configure(config.setup({
  auto_connect = false,
  poll_interval_ms = 60000,
}))
tools.enable_defaults()

local templates = tools._templates()
assert(#templates == 7)
assert(
  table.concat(vim.tbl_map(function(item) return item.id end, templates), ",")
    == table.concat({
      "nvim.context.buffer",
      "nvim.context.buffers",
      "nvim.context.current_location",
      "nvim.context.diagnostics",
      "nvim.context.quickfix",
      "nvim.context.selection",
      "nvim.context.viewport",
    }, ",")
)

local by_id = {}
for _, template in ipairs(templates) do
  by_id[template.id] = template
  assert(template.definition.requires_permission == false)
end
assert(by_id["nvim.context.current_location"].definition.input.type == "unit")
assert(by_id["nvim.context.selection"].definition.output.type == "option")
assert(by_id["nvim.context.buffer"].definition.input.type == "table")
assert(by_id["nvim.context.buffer"].definition.input.value.max_bytes.type == "option")
assert(by_id["nvim.context.diagnostics"].definition.input.value.limit.type == "option")
assert(by_id["nvim.context.quickfix"].definition.input.value.limit.type == "option")
assert(by_id["nvim.context.viewport"].definition.input.value.max_bytes.type == "option")
assert(by_id["nvim.context.buffers"].definition.output.type == "list")

local buffer = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { "éx", "second" })
vim.bo[buffer].filetype = "lua"
local buffer_result = by_id["nvim.context.buffer"].handler({
  uri = nil,
  max_bytes = 1,
})
assert(buffer_result.truncated == true)
assert(buffer_result.text == "", "UTF-8 truncation split a code point")
assert(buffer_result.info.filetype == "lua")
assert(buffer_result.changedtick == vim.api.nvim_buf_get_changedtick(buffer))

local full_buffer = by_id["nvim.context.buffer"].handler({
  uri = nil,
})
assert(full_buffer.text == "éx\nsecond")
assert(full_buffer.truncated == false)

-- Bounded reads must not request the entire buffer before truncating. Even a
-- tiny snapshot must inspect only the first needed line(s).
local previous_get_lines = vim.api.nvim_buf_get_lines
local inspected_lines = 0
vim.api.nvim_buf_get_lines = function(buf, first, last, strict)
  if buf == buffer then
    assert(last ~= -1, "bounded buffer tool fetched the complete buffer")
    inspected_lines = inspected_lines + (last - first)
  end
  return previous_get_lines(buf, first, last, strict)
end
local bounded_ok, bounded_result = pcall(by_id["nvim.context.buffer"].handler, {
  uri = nil,
  max_bytes = 2,
})
vim.api.nvim_buf_get_lines = previous_get_lines
assert(bounded_ok, bounded_result)
assert(bounded_result.text == "é" and bounded_result.truncated,
  "UTF-8 boundary should return only the permitted whole code point")
assert(inspected_lines <= 2, "bounded buffer tool read beyond the byte budget")

-- Cursor columns are zero-based UTF-8 byte offsets. The first character is
-- two bytes wide, so column 2 points at the following ASCII character.
vim.api.nvim_win_set_cursor(0, { 1, 2 })
local location = by_id["nvim.context.current_location"].handler()
assert(type(location.uri) == "string" and location.uri ~= "")
assert(vim.deep_equal(location.range, {
  start = { line = 0, column = 2 },
  ["end"] = { line = 0, column = 2 },
}), "current location must preserve the exact cursor byte offset")

local listed = by_id["nvim.context.buffers"].handler()
assert(#listed >= 1)

local namespace = vim.api.nvim_create_namespace("phenix-client-tool-test")
vim.diagnostic.set(namespace, buffer, {
  {
    lnum = 0,
    col = 0,
    end_lnum = 0,
    end_col = 2,
    severity = vim.diagnostic.severity.ERROR,
    message = "fixture diagnostic",
    source = "fixture",
    code = 7,
  },
})
local diagnostics = by_id["nvim.context.diagnostics"].handler({
  uri = nil,
})
assert(#diagnostics == 1)
assert(diagnostics[1].severity == "error")
assert(diagnostics[1].code == "7")
vim.diagnostic.reset(namespace, buffer)

vim.fn.setqflist({}, "r", {
  items = {
    {
      bufnr = buffer,
      lnum = 1,
      col = 1,
      text = "fixture quickfix",
      type = "E",
    },
  },
})
local quickfix = by_id["nvim.context.quickfix"].handler({})
assert(#quickfix == 1 and quickfix[1].text == "fixture quickfix")
local empty_quickfix = by_id["nvim.context.quickfix"].handler({ limit = 0 })
assert(#empty_quickfix == 0, "zero quickfix limit must return no entries")

local viewport = by_id["nvim.context.viewport"].handler({})
assert(viewport.truncated == false)

runtime.connect()
client:ready()
runtime.tick()

local created
runtime.new_session(function(value, error)
  assert(error == nil)
  created = value
end)
runtime.tick()
assert(created ~= nil)

local prompt_result
runtime.prompt("session.tools", { { kind = "text", text = "inspect editor" } }, function(value, error)
  assert(error == nil)
  prompt_result = value
end)

assert(client.prompt_calls == 0, "prompt bypassed tool admission")
for _ = 1, 12 do
  runtime.tick()
end
assert(#client.registrations == 7)
assert(client.prompt_calls == 1)
assert(prompt_result and prompt_result.execution_id == "execution.tools")
for index, expected in ipairs({
  "nvim.context.buffer",
  "nvim.context.buffers",
  "nvim.context.current_location",
  "nvim.context.diagnostics",
  "nvim.context.quickfix",
  "nvim.context.selection",
  "nvim.context.viewport",
}) do
  assert(client.registrations[index].definition.id == expected)
  assert(client.registrations[index].definition.session_id == "session.tools")
end

runtime.disconnect()

-- A client may register its own implementation of a default tool before
-- enabling defaults. Enabling must not reject, shadow or remove that handler.
tools.disable_defaults()
assert(#tools._templates() == 0)
local custom_definition = vim.deepcopy(by_id["nvim.context.buffer"].definition)
local custom_handler = function() return "custom context" end
local stop_custom = tools.register(custom_definition, custom_handler)
tools.enable_defaults()
local customized = tools._templates()
assert(#customized == 7, "default tools should fill only missing IDs")
local found_custom
for _, item in ipairs(customized) do
  if item.id == "nvim.context.buffer" then
    found_custom = item
  end
end
assert(found_custom and found_custom.handler == custom_handler,
  "custom tool handler was overwritten by default registration")
tools.disable_defaults()
local remaining = tools._templates()
assert(#remaining == 1 and remaining[1].handler == custom_handler,
  "disabling defaults removed a third-party tool")
stop_custom()
tools.enable_defaults()
assert(#tools._templates() == 7, "default must become available after custom removal")
tools.disable_defaults()

print("client context tool regressions passed")
