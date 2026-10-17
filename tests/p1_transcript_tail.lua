-- Exercise both tail helpers with real nonempty buffer lines.
vim.deprecate = function(name)
  error("deprecated API: " .. name)
end
local buffer = require("phenix_nvim.transcript.buffer")
local key = {}
local target = buffer.ensure(key)
local win = vim.api.nvim_get_current_win()
vim.api.nvim_win_set_buf(win, target)
local cases = {
  { "ASCII", "hello", 4 },
  { "emoji", "a" .. vim.fn.nr2char(0x1f600), 1 },
  { "multibyte", "a" .. vim.fn.nr2char(0x754c), 1 },
  { "combining", "ae" .. vim.fn.nr2char(0x301), 2 },
  { "empty", "", 0 },
}
for _, case in ipairs(cases) do
  vim.bo[target].modifiable = true
  vim.api.nvim_buf_set_lines(target, 0, -1, false, { case[2] })
  vim.bo[target].modifiable = false
  buffer.attach_window(key, win)
  buffer.set_follow_tail(true, win, key)
  assert(vim.deep_equal(vim.api.nvim_win_get_cursor(win), { 1, case[3] }),
    case[1] .. ": tail cursor must land on the last character")
  vim.api.nvim_exec_autocmds("WinScrolled", { pattern = tostring(win) })
  assert(buffer.is_following_tail(win, key), case[1] .. ": visible tail must be followed")
end
vim.bo[target].modifiable = true
vim.api.nvim_buf_set_lines(target, 0, -1, false, { string.rep("wrapped text ", 2000) })
vim.bo[target].modifiable = false
vim.api.nvim_win_set_cursor(win, { 1, 0 })
vim.api.nvim_win_call(win, function() vim.cmd("normal! zt") end)
vim.api.nvim_exec_autocmds("WinScrolled", { pattern = tostring(win) })
assert(not buffer.is_following_tail(win, key), "partial wrapped final line is not the tail")
vim.api.nvim_win_call(win, function() vim.cmd("normal! G$zb") end)
vim.api.nvim_exec_autocmds("WinScrolled", { pattern = tostring(win) })
assert(buffer.is_following_tail(win, key), "visible wrapped line end must restore follow-tail")
buffer.detach_window(win)
print("P1 transcript Unicode tail accepted (deprecations fatal)")
