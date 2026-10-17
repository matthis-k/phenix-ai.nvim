-- Installed P1 transcript presentation: compact/human/protocol are
-- Neovim-only display controls. They never modify Phenix session authority.
vim.deprecate = function(name)
  error("deprecated API: " .. name)
end
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
-- Deprecated nvim_buf_add_highlight() was replaced with extmarks; both
-- the fixed-width tool label and dynamic status must remain visible.
local style_ns = assert(vim.api.nvim_get_namespaces()["phenix-transcript-style"])
local extmarks = vim.api.nvim_buf_get_extmarks(bufnr, style_ns, 0, -1, { details = true })
local groups = {}
for _, mark in ipairs(extmarks) do
  groups[mark[4].hl_group] = true
end
assert(groups.PhenixToolLabel and groups.PhenixToolRunning,
  "tool label and running status must have extmark highlights")
assert(buffer.set_tool_mode(win, nil, "human"), "tool disclosure could not open")
local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
assert(vim.inspect(lines):find("printf hello", 1, true))
assert(buffer.toggle_tool(win), "tool disclosure could not advance")
lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
assert(vim.inspect(lines):find("Stream", 1, true), "protocol mode not displayed")
buffer.detach_window(win)
-- Inspect the actual bytes covered, not just the presence of highlight groups.
for _, state in ipairs({ "running", "completed", "failed" }) do
  for _, mode in ipairs({ "compact", "human", "protocol" }) do
    node.state = state
    node.callable_id = state .. ".worker"
    buffer.render_projection({ order = { node.id }, nodes = { [node.id] = node } })
    vim.api.nvim_win_set_cursor(win, { 1, 0 })
    assert(buffer.set_tool_mode(win, buffer.default_key(), mode))
    local header = vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1]
    local status, status_group = tool_view.status(state)
    local covered = {}
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, style_ns, 0, -1, { details = true })) do
      local details = mark[4]
      covered[details.hl_group] = { text = header:sub(mark[3] + 1, details.end_col), col = mark[3] }
    end
    assert(covered[status_group].text == status, "status highlight covers incorrect bytes")
    assert(covered[status_group].col == #header - #status,
      state .. "/" .. mode .. ": status highlight covers callable substring, not suffix")
    assert(covered.PhenixToolLabel.text == "Tool", state .. "/" .. mode .. ": label covers marker, not Tool")
  end
end
print("P1 installed transcript character-cell disclosure accepted")
