local config = require("phenix_nvim.config")
local state = require("phenix_nvim.state")
local compose = require("phenix_nvim.compose.buffer")
local transcript = require("phenix_nvim.transcript.buffer")
local winbar = require("phenix_nvim.winbar")

local M = {}
local group = vim.api.nvim_create_augroup("phenix-sidebar", { clear = true })
local layouts = {}

local function valid_window(win)
  return win ~= nil and vim.api.nvim_win_is_valid(win)
end

local function valid_tab(tab)
  return tab ~= nil and vim.api.nvim_tabpage_is_valid(tab)
end

local function window_matches(win, tab, target)
  return valid_window(win)
    and valid_tab(tab)
    and vim.api.nvim_win_get_tabpage(win) == tab
    and vim.api.nvim_win_get_buf(win) == target
end

local function remember_cursor(layout)
  if layout ~= nil and valid_window(layout.compose_win) then
    local cursor = vim.api.nvim_win_get_cursor(layout.compose_win)
    layout.compose_cursor = cursor
    state.remembered_compose_cursor = cursor
  end
end

local function detach(layout)
  if layout == nil then
    return
  end
  winbar.detach(layout.transcript_win, layout.compose_win)
  compose.detach_window(layout.compose_win)
  transcript.detach_window(layout.transcript_win)
end

local function discard(tab, close_windows)
  local layout = layouts[tab]
  if layout == nil then
    return
  end
  layouts[tab] = nil
  layout.closing = true
  remember_cursor(layout)
  detach(layout)
  if close_windows then
    for _, win in ipairs({ layout.compose_win, layout.transcript_win }) do
      if valid_window(win) then
        pcall(vim.api.nvim_win_close, win, true)
      end
    end
  end
end

local function reconcile(tab)
  local layout = layouts[tab]
  if layout == nil or layout.closing then
    return nil
  end
  if not valid_tab(tab) then
    discard(tab, false)
    return nil
  end
  local transcript_buffer = transcript.ensure()
  local compose_buffer = compose.ensure(state.compose)
  if window_matches(layout.transcript_win, tab, transcript_buffer)
    and window_matches(layout.compose_win, tab, compose_buffer)
  then
    return layout
  end
  discard(tab, true)
  return nil
end

local function activate(layout)
  if layout == nil then
    return
  end
  transcript.attach_window(layout.transcript_win)
  compose.attach_window(state.compose, layout.compose_win)
  winbar.attach(layout.transcript_win, layout.compose_win)
end

function M.is_open()
  return reconcile(vim.api.nvim_get_current_tabpage()) ~= nil
end

function M.remember_cursor()
  remember_cursor(reconcile(vim.api.nvim_get_current_tabpage()))
end

function M.open()
  local tab = vim.api.nvim_get_current_tabpage()
  local layout = reconcile(tab)
  if layout ~= nil then
    activate(layout)
    winbar.refresh()
    return layout.compose_win
  end

  local options = config.get()
  vim.cmd(options.side == "left" and "topleft vsplit" or "botright vsplit")
  local transcript_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_width(transcript_win, options.width)
  vim.api.nvim_win_set_buf(transcript_win, transcript.ensure())

  vim.cmd("belowright split")
  local compose_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_height(compose_win, options.compose_height)
  vim.api.nvim_win_set_buf(compose_win, compose.ensure(state.compose))

  layout = {
    tab = tab,
    transcript_win = transcript_win,
    compose_win = compose_win,
    compose_cursor = vim.deepcopy(state.remembered_compose_cursor),
    closing = false,
  }
  layouts[tab] = layout
  activate(layout)
  pcall(vim.api.nvim_win_set_cursor, compose_win, layout.compose_cursor)
  return compose_win
end

function M.close()
  discard(vim.api.nvim_get_current_tabpage(), true)
end

function M.toggle()
  if M.is_open() then
    M.close()
  else
    M.open()
  end
end

function M.focus_compose()
  local win = M.open()
  if valid_window(win) then
    vim.api.nvim_set_current_win(win)
    local layout = reconcile(vim.api.nvim_get_current_tabpage())
    local cursor = layout and layout.compose_cursor or state.remembered_compose_cursor
    pcall(vim.api.nvim_win_set_cursor, win, cursor)
  end
  return win
end

function M.buffers()
  return transcript.ensure(), compose.ensure(state.compose)
end

function M.windows()
  local layout = reconcile(vim.api.nvim_get_current_tabpage())
  if layout == nil then
    return nil, nil
  end
  return layout.transcript_win, layout.compose_win
end

vim.api.nvim_create_autocmd("WinClosed", {
  group = group,
  callback = function(args)
    local closed = tonumber(args.match)
    if closed == nil then
      return
    end
    for tab, layout in pairs(layouts) do
      if not layout.closing and (layout.transcript_win == closed or layout.compose_win == closed) then
        vim.schedule(function()
          if layouts[tab] == layout then
            discard(tab, true)
          end
        end)
      end
    end
  end,
})

vim.api.nvim_create_autocmd("BufWinLeave", {
  group = group,
  callback = function(args)
    local transcript_buffer, compose_buffer = M.buffers()
    if args.buf ~= transcript_buffer and args.buf ~= compose_buffer then
      return
    end
    vim.schedule(function()
      for tab in pairs(layouts) do
        reconcile(tab)
      end
    end)
  end,
})

vim.api.nvim_create_autocmd("TabLeave", {
  group = group,
  callback = function()
    local layout = reconcile(vim.api.nvim_get_current_tabpage())
    if layout ~= nil then
      remember_cursor(layout)
      compose.detach_window(layout.compose_win)
    end
  end,
})

vim.api.nvim_create_autocmd({ "TabEnter", "WinEnter" }, {
  group = group,
  callback = function()
    vim.schedule(function()
      local layout = reconcile(vim.api.nvim_get_current_tabpage())
      if layout ~= nil then
        activate(layout)
      end
    end)
  end,
})

return M
