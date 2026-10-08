-- A headless Neovim test: every follow-up is a real editable buffer/window.
local mapped = {}
package.loaded["phenix_nvim.sidebar"] = {
  attach_queue_window = function(_, win) mapped[win] = true end,
  detach_queue_window = function(win) mapped[win] = nil end,
  reconcile = function() end,
}

local queue = require("phenix_nvim.queue")
local host = vim.api.nvim_get_current_win()
local compose_buf = vim.api.nvim_create_buf(false, true)
local compose = vim.api.nvim_open_win(compose_buf, false, {
  relative = "win", win = host, row = vim.api.nvim_win_get_height(host) - 3,
  col = 0, width = vim.api.nvim_win_get_width(host), height = 3,
  style = "minimal", border = "none",
})
local surface = { host_win = host, compose_win = compose }
local first = {
  ready = true, revision = 0, session_id = "one",
  content = {
    { kind = "text", text = "first draft" },
    { kind = "image", mime_type = "image/png", bytes = "unchanged-image" },
  },
}
local second = {
  ready = true, revision = 0, session_id = "one",
  content = { { kind = "text", text = "second draft" } },
}
local removed = {}
local wakes = 0
local items = { first, second }
queue.render(surface, items, function(index) removed[#removed + 1] = index end,
  function() end, function() wakes = wakes + 1 end)
local buffers = queue.buffers(surface)
assert(#buffers == 2 and buffers[1] ~= buffers[2])
assert(vim.bo[buffers[1]].buftype == "acwrite")
assert(vim.bo[buffers[1]].modifiable)
assert(vim.api.nvim_buf_get_lines(buffers[1], 0, 1, false)[1] == "first draft")
local w1, w2 = vim.fn.bufwinid(buffers[1]), vim.fn.bufwinid(buffers[2])
assert(w1 > 0 and w2 > 0 and mapped[w1] and mapped[w2)
local config1 = vim.api.nvim_win_get_config(w1)
local config2 = vim.api.nvim_win_get_config(w2)
assert(config1.win == host and config2.win == host)
local function row(config)
  return type(config.row) == "table" and config.row[2] or config.row
end
assert(row(config2) == row(config1) + 3)
assert(queue.reserved_rows(surface, vim.api.nvim_win_get_height(host), 3) == 6)

vim.api.nvim_set_current_win(w1)
queue.on_focus(w1)
assert(not queue.can_dispatch(surface, first), "focused draft must hold pickup")
vim.api.nvim_buf_set_lines(buffers[1], 0, -1, false, { "edited before sending" })
vim.api.nvim_exec_autocmds("TextChanged", { buffer = buffers[1] })
assert(not first.ready and not queue.can_dispatch(surface, first))
vim.api.nvim_set_current_win(compose)
assert(not queue.can_dispatch(surface, first), "dirty buffer must stay held after blur")
vim.api.nvim_set_current_win(w1)
vim.cmd("write")
assert(first.ready and first.revision == 1)
assert(first.content[1].text == "edited before sending")
assert(first.content[2].kind == "image" and first.content[2].bytes == "unchanged-image")
assert(queue.can_dispatch(surface, first), "write must release even while focused")

first.pending = { revision = first.revision }
queue.set_claimed(surface, first, true)
assert(not vim.bo[buffers[1]].modifiable)
assert(not queue.can_dispatch(surface, first), "claimed revision cannot be consumed twice")
first.pending = nil
queue.set_claimed(surface, first, false)
assert(vim.bo[buffers[1]].modifiable)
assert(queue.can_dispatch(surface, first))

table.remove(items, 1)
queue.render(surface, items, function(index) removed[#removed + 1] = index end,
  function() end, function() wakes = wakes + 1 end)
assert(#queue.buffers(surface) == 1 and queue.buffers(surface)[1] == buffers[2])
assert(not vim.api.nvim_buf_is_valid(buffers[1]))
assert(vim.api.nvim_buf_is_valid(buffers[2]))
queue.close(surface)
assert(not vim.api.nvim_buf_is_valid(buffers[2]))
assert(next(mapped) == nil)
vim.api.nvim_win_set_current_win(host)
vim.api.nvim_win_close(compose, true)
