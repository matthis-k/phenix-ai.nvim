-- Installed P1 transcript presentation: compact/human/protocol are
-- Neovim-only display controls. They never modify Phenix session authority.
local tool_view = require("phenix_nvim.transcript.tool_view")
local buffer = require("phenix_nvim.transcript.buffer")
local node = {
  id = "tool-one",
  kind = "tool",
  callable_id = "workspace.shell",
  state = "running",
  input = { command = "printf hello" },
  output_streams = { stdout = "hello\n" .. string.char(27) .. "[2J", stderr = "" },
}
local compact = tool_view.lines(node, "compact", 68)
assert(#compact == 1 and compact[1]:find("workspace.shell", 1, true))
local human = tool_view.lines(node, "human", 68)
assert(#human > 1 and vim.inspect(human):find("printf hello", 1, true))
assert(not vim.inspect(human):find(string.char(27), 1, true),
  "human-readable output must strip terminal controls")
local protocol = tool_view.lines(node, "protocol", 68)
assert(#protocol > #compact and vim.inspect(protocol):find("Stream", 1, true))
assert(tool_view.next_mode("compact") == "human"
  and tool_view.next_mode("human") == "protocol"
  and tool_view.next_mode("protocol") == "compact")

buffer.render_projection({ order = { node.id }, nodes = { [node.id] = node } })
local bufnr = buffer.ensure()
local win = vim.api.nvim_get_current_win()
vim.api.nvim_win_set_buf(win, bufnr)
buffer.attach_window(win)
vim.api.nvim_win_set_cursor(win, { 1, 0 })
assert(vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1]:find("workspace.shell", 1, true))
assert(buffer.set_tool_mode(win, nil, "human"), "tool disclosure could not open")
local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
assert(vim.inspect(lines):find("printf hello", 1, true))
assert(buffer.toggle_tool(win), "tool disclosure could not advance")
lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
assert(vim.inspect(lines):find("Stream", 1, true), "protocol mode not displayed")
buffer.detach_window(win)
print("P1 installed transcript character-cell disclosure accepted")
