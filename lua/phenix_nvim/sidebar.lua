local config = require("phenix_nvim.config")
local state = require("phenix_nvim.state")
local compose = require("phenix_nvim.compose.buffer")
local transcript = require("phenix_nvim.transcript.buffer")
local winbar = require("phenix_nvim.winbar")

local M = {}
local group = vim.api.nvim_create_augroup("phenix-sidebar", { clear = true })
local layouts = {}
local host_buffer

local function valid_window(win)
  return win ~= nil and vim.api.nvim_win_is_valid(win)
end

local function valid_tab(tab)
  return tab ~= nil and vim.api.nvim_tabpage_is_valid(tab)
end

local function ensure_host_buffer()
  if host_buffer ~= nil and vim.api.nvim_buf_is_valid(host_buffer) then
    return host_buffer
  end
  host_buffer = vim.api.nvim_create_buf(false, true)
  vim.bo[host_buffer].buftype = "nofile"
  vim.bo[host_buffer].bufhidden = "hide"
  vim.bo[host_buffer].swapfile = false
  vim.bo[host_buffer].modifiable = false
  vim.bo[host_buffer].filetype = "phenix-sidebar"
  vim.api.nvim_buf_set_name(host_buffer, "phenix://sidebar-host")
  return host_buffer
end

local function window_matches(win, tab, target)
  return valid_window(win)
    and valid_tab(tab)
    and vim.api.nvim_win_get_tabpage(win) == tab
    and vim.api.nvim_win_get_buf(win) == target
end

local function host_matches(layout)
  return layout ~= nil and window_matches(layout.host_win, layout.tab, ensure_host_buffer())
end

local function sidebar_width(value)
  if value <= 1 then
    return math.max(20, math.floor(vim.o.columns * value))
  end
  return math.max(1, math.floor(value))
end

local function apply_host_options(win)
  if not valid_window(win) then
    return
  end
  vim.wo[win].winfixwidth = true
  vim.wo[win].wrap = false
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].foldcolumn = "0"
  vim.wo[win].cursorline = false
  vim.wo[win].winbar = ""
  vim.wo[win].statusline = " "
end

local function remember_cursor(layout)
  if layout ~= nil and valid_window(layout.compose_win) then
    local cursor = vim.api.nvim_win_get_cursor(layout.compose_win)
    layout.compose_cursor = cursor
    state.remembered_compose_cursor = cursor
  end
end

local function detach_children(layout)
  if layout == nil then
    return
  end
  winbar.detach(layout.transcript_win, layout.compose_win)
  compose.detach_window(layout.compose_win)
  transcript.detach_window(layout.transcript_win)
end

local function close_window(win)
  if valid_window(win) then
    pcall(vim.api.nvim_win_close, win, true)
  end
end

local function remove_layout(tab, close_host)
  local layout = layouts[tab]
  if layout == nil then
    return
  end
  layouts[tab] = nil
  layout.closing = true
  remember_cursor(layout)
  detach_children(layout)
  close_window(layout.compose_win)
  close_window(layout.transcript_win)
  if close_host then
    close_window(layout.host_win)
  end
end

local function resize_host(layout)
  if not host_matches(layout) then
    return
  end
  apply_host_options(layout.host_win)
  pcall(vim.api.nvim_win_set_width, layout.host_win, sidebar_width(config.get().width))
end

local function geometry(layout)
  local width = math.max(1, vim.api.nvim_win_get_width(layout.host_win))
  local height = math.max(2, vim.api.nvim_win_get_height(layout.host_win))
  local requested_compose = math.max(1, math.floor(config.get().compose_height))
  local compose_height = math.min(requested_compose, height - 1)
  local transcript_height = math.max(1, height - compose_height)
  return {
    width = width,
    transcript_height = transcript_height,
    compose_height = compose_height,
  }
end

local function float_config(layout, role)
  local size = geometry(layout)
  local is_compose = role == "compose"
  return {
    relative = "win",
    win = layout.host_win,
    anchor = "NW",
    row = is_compose and size.transcript_height or 0,
    col = 0,
    width = size.width,
    height = is_compose and size.compose_height or size.transcript_height,
    style = "minimal",
    border = "none",
    focusable = true,
    zindex = is_compose and 61 or 60,
  }
end

local function ensure_float(layout, role, target)
  local field = role .. "_win"
  local win = layout[field]
  local expected = window_matches(win, layout.tab, target)
  if expected then
    pcall(vim.api.nvim_win_set_config, win, float_config(layout, role))
    return win
  end

  close_window(win)
  win = vim.api.nvim_open_win(target, false, float_config(layout, role))
  layout[field] = win
  return win
end

local function sync_layout(layout)
  if layout == nil or layout.closing or not host_matches(layout) then
    return false
  end
  resize_host(layout)
  local transcript_win = ensure_float(layout, "transcript", transcript.ensure())
  local compose_win = ensure_float(layout, "compose", compose.ensure(state.compose))
  transcript.attach_window(transcript_win)
  compose.attach_window(state.compose, compose_win)
  winbar.attach(transcript_win, compose_win)
  return true
end

local function reconcile(tab)
  local layout = layouts[tab]
  if layout == nil or layout.closing then
    return nil
  end
  if not valid_tab(tab) or not host_matches(layout) then
    remove_layout(tab, false)
    return nil
  end
  if not sync_layout(layout) then
    remove_layout(tab, false)
    return nil
  end
  return layout
end

local function focus_child(layout, role)
  if layout == nil or not valid_tab(layout.tab) or vim.api.nvim_get_current_tabpage() ~= layout.tab then
    return
  end
  local win = layout[role .. "_win"]
  if valid_window(win) then
    vim.api.nvim_set_current_win(win)
    if role == "compose" then
      pcall(vim.api.nvim_win_set_cursor, win, layout.compose_cursor or state.remembered_compose_cursor)
    end
  end
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
    winbar.refresh()
    focus_child(layout, "compose")
    return layout.compose_win
  end

  local options = config.get()
  vim.cmd(options.side == "left" and "topleft vsplit" or "botright vsplit")
  local host_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(host_win, ensure_host_buffer())

  layout = {
    tab = tab,
    host_win = host_win,
    transcript_win = nil,
    compose_win = nil,
    compose_cursor = vim.deepcopy(state.remembered_compose_cursor),
    closing = false,
  }
  layouts[tab] = layout
  resize_host(layout)
  sync_layout(layout)
  focus_child(layout, "compose")
  return layout.compose_win
end

function M.close()
  remove_layout(vim.api.nvim_get_current_tabpage(), true)
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
  local layout = reconcile(vim.api.nvim_get_current_tabpage())
  focus_child(layout, "compose")
  return win
end

function M.buffers()
  return transcript.ensure(), compose.ensure(state.compose)
end

function M.windows()
  local layout = reconcile(vim.api.nvim_get_current_tabpage())
  if layout == nil then
    return nil, nil, nil
  end
  return layout.transcript_win, layout.compose_win, layout.host_win
end

vim.api.nvim_create_autocmd("WinClosed", {
  group = group,
  callback = function(args)
    local closed = tonumber(args.match)
    if closed == nil then
      return
    end
    for tab, layout in pairs(layouts) do
      if not layout.closing then
        if layout.host_win == closed then
          vim.schedule(function()
            if layouts[tab] == layout then
              remove_layout(tab, false)
            end
          end)
        elseif layout.transcript_win == closed or layout.compose_win == closed then
          local role = layout.transcript_win == closed and "transcript" or "compose"
          vim.schedule(function()
            if layouts[tab] == layout and sync_layout(layout) then
              focus_child(layout, role)
            end
          end)
        end
      end
    end
  end,
})

vim.api.nvim_create_autocmd("BufWinLeave", {
  group = group,
  callback = function()
    vim.schedule(function()
      for tab, layout in pairs(layouts) do
        if not layout.closing then
          if not host_matches(layout) then
            remove_layout(tab, false)
          else
            sync_layout(layout)
          end
        end
      end
    end)
  end,
})

vim.api.nvim_create_autocmd("TabLeave", {
  group = group,
  callback = function()
    local layout = layouts[vim.api.nvim_get_current_tabpage()]
    if layout ~= nil and not layout.closing then
      remember_cursor(layout)
      compose.detach_window(layout.compose_win)
    end
  end,
})

vim.api.nvim_create_autocmd({ "TabEnter", "WinEnter" }, {
  group = group,
  callback = function()
    vim.schedule(function()
      reconcile(vim.api.nvim_get_current_tabpage())
    end)
  end,
})

vim.api.nvim_create_autocmd({ "VimResized", "WinResized" }, {
  group = group,
  callback = function()
    vim.schedule(function()
      for tab, layout in pairs(layouts) do
        if valid_tab(tab) and not layout.closing then
          if not sync_layout(layout) then
            remove_layout(tab, false)
          end
        end
      end
    end)
  end,
})

return M
