-- Real scratch buffers and buffer-local normal-mode keymaps (no UI plugin).
-- Force the native presentation in headless Neovim for deterministic tests.
local ui = require("phenix_nvim.ui.auth")
local origin = vim.api.nvim_get_current_win()

local function mapping(buffer, lhs)
  for _, item in ipairs(vim.api.nvim_buf_get_keymap(buffer, "n")) do
    if item.lhs == lhs then
      assert(type(item.callback) == "function", lhs .. " must have a native callback")
      return item.callback
    end
  end
  error("Missing buffer-local normal-mode " .. lhs .. " mapping")
end

local chosen, selected_count
local function picker()
  return ui.select({ "OpenAI API", "OpenAI ChatGPT" }, {
    force_native = true,
    prompt = "Phenix provider",
  }, function(value)
    selected_count = selected_count + 1
    chosen = value
  end)
end

-- Escape and q are both cancellation, never selection or authentication.
for _, key in ipairs({ "q", "<Esc>" }) do
  chosen, selected_count = "unchanged", 0
  local view = picker()
  assert(vim.api.nvim_get_current_buf() == view.buffer)
  local cancel = mapping(view.buffer, key)
  cancel()
  assert(chosen == nil and selected_count == 1)
  assert(not vim.api.nvim_buf_is_valid(view.buffer), "scratch picker must be wiped")
  assert(vim.api.nvim_get_current_win() == origin, "auth picker must restore focus")
end

chosen, selected_count = nil, 0
local select_view = picker()
mapping(select_view.buffer, "2")()
assert(chosen == "OpenAI ChatGPT" and selected_count == 1)
assert(vim.api.nvim_get_current_win() == origin)
local done = 0
-- Modal closes programmatically without triggering cancellation.
local before = vim.api.nvim_list_uis
vim.api.nvim_list_uis = function() return { {} } end
local status = ui.pending("Sign in with ChatGPT", function() done = done + 1 end)
assert(status and vim.api.nvim_get_current_buf() == status.buffer)
mapping(status.buffer, "<Esc>")()
assert(done == 1)
assert(not vim.api.nvim_buf_is_valid(status.buffer))
status.close()
assert(done == 1, "terminal state must not run cancel a second time")
status = ui.pending("Sign in with ChatGPT", function() done = done + 1 end)
status.close()
assert(done == 1, "verified success must close without revoking")
vim.api.nvim_list_uis = before
assert(vim.api.nvim_get_current_win() == origin)

print("Native Phenix auth picker q/Esc/selection/focus and OAuth modal teardown accepted")
