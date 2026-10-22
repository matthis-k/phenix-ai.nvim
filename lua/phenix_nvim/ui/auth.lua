-- Buffer-local, Neovim-native authentication surfaces.
-- Never changes user mappings, uses the caller's current window as the
-- return target and owns no credentials or provider authentication state.
local M = {}

local function native_available()
  return vim.api and vim.api.nvim_list_uis and #vim.api.nvim_list_uis() > 0
end

local function create_surface(title, lines, width)
  local origin = vim.api.nvim_get_current_win()
  local buffer = vim.api.nvim_create_buf(false, true)
  vim.bo[buffer].buftype = "nofile"
  vim.bo[buffer].bufhidden = "wipe"
  vim.bo[buffer].swapfile = false
  vim.bo[buffer].filetype = "phenix-auth"
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, lines)
  vim.bo[buffer].modifiable = false
  local height = #lines
  local columns = math.max(20, vim.o.columns - 4)
  width = math.min(columns, math.max(24, width))
  local win = vim.api.nvim_open_win(buffer, true, {
    relative = "editor",
    style = "minimal",
    border = "single",
    title = " " .. title .. " ",
    title_pos = "left",
    width = width,
    height = height,
    row = math.max(0, math.floor((vim.o.lines - height - 2) / 2)),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    noautocmd = false,
  })
  vim.wo[win].wrap = false
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  local closed = false
  local function close()
    if closed then return false end
    closed = true
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
    if vim.api.nvim_win_is_valid(origin) then
      pcall(vim.api.nvim_set_current_win, origin)
    end
    return true
  end
  return buffer, win, close
end

local function map(buffer, lhs, action)
  vim.keymap.set("n", lhs, action, {
    buffer = buffer, silent = true, noremap = true, nowait = true,
  })
end

-- Native when a terminal/GUI is attached; headless runs delegate to vim.ui
-- so plugins and deterministic tests can inject the usual select callback.
function M.select(items, opts, callback)
  opts = opts or {}
  if not opts.force_native and not native_available() then
    return vim.ui.select(items, opts, callback)
  end
  local labels = {}
  local width = vim.fn.strdisplaywidth(opts.prompt or "Authentication")
  for i, item in ipairs(items) do
    local label = opts.format_item and opts.format_item(item) or tostring(item)
    labels[i] = tostring(label)
    width = math.max(width, vim.fn.strdisplaywidth(labels[i]) + 4)
  end
  local lines = { opts.prompt or "Authentication", "" }
  for i, label in ipairs(labels) do
    lines[#lines + 1] = string.format(" %d  %s", i, label)
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = " j/k move   Enter select   q/Esc cancel"
  local buffer, win, close = create_surface("Phenix auth", lines, width + 5)
  vim.wo[win].cursorline = true
  local settled = false
  local function finish(index)
    if settled then return end
    settled = true
    close()
    callback(index and items[index] or nil, index)
  end
  if #items > 0 then
    vim.api.nvim_win_set_cursor(win, { 3, 0 })
  end
  map(buffer, "<CR>", function()
    local index = vim.api.nvim_win_get_cursor(win)[1] - 2
    if index >= 1 and index <= #items then finish(index) end
  end)
  map(buffer, "<Esc>", function() finish(nil) end)
  map(buffer, "q", function() finish(nil) end)
  for i = 1, math.min(#items, 9) do
    local index = i
    map(buffer, tostring(i), function() finish(index) end)
  end
  vim.api.nvim_create_autocmd("CursorMoved", {
    buffer = buffer,
    callback = function()
      if not vim.api.nvim_win_is_valid(win) or #items == 0 then return end
      local pos = vim.api.nvim_win_get_cursor(win)
      local constrained = math.max(3, math.min(2 + #items, pos[1]))
      if pos[1] ~= constrained then
        vim.api.nvim_win_set_cursor(win, { constrained, 0 })
      end
    end,
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(win),
    once = true,
    callback = function()
      if not settled then
        settled = true
        callback(nil, nil)
      end
    end,
  })
  return { close = function() finish(nil) end, buffer = buffer }
end

-- A visible modal for a provider-owned, already-started OAuth attempt.
-- Dismissing the view calls on_cancel; closing it after a provider result
-- does not revoke a completed account. No tokens or callback URI are shown.
function M.pending(title, on_cancel)
  if not native_available() then return nil end
  local lines = {
    " Waiting for browser authorization",
    "",
    " Complete sign-in in your browser.",
    " Phenix will verify the account automatically.",
    "",
    " q/Esc cancel authentication",
  }
  local buffer, win, close = create_surface(title or "Phenix auth", lines, 50)
  local finished = false
  local function cancel()
    if finished then return end
    finished = true
    close()
    on_cancel()
  end
  map(buffer, "q", cancel)
  map(buffer, "<Esc>", cancel)
  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(win),
    once = true,
    callback = function()
      if not finished then
        finished = true
        on_cancel()
      end
    end,
  })
  return {
    buffer = buffer,
    close = function()
      if finished then return end
      finished = true
      close()
    end,
  }
end

return M
