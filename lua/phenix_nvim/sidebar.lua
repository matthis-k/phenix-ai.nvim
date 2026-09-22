local config = require("phenix_nvim.config")
local state = require("phenix_nvim.state")
local compose = require("phenix_nvim.compose.buffer")
local compose_model = require("phenix_nvim.compose.model")
local runtime = require("phenix_nvim.runtime")
local transcript = require("phenix_nvim.transcript.buffer")
local transcript_controller = require("phenix_nvim.transcript.controller")
local winbar = require("phenix_nvim.winbar")

local M = {}
local group = vim.api.nvim_create_augroup("phenix-sidebar", { clear = true })
local surfaces = {}
local window_surfaces = {}
local last_surface_by_tab = {}
local host_buffer
local default_surface
local next_surface_id = 0

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

local function host_matches(surface)
  return surface ~= nil and window_matches(surface.host_win, surface.tab, ensure_host_buffer())
end

local function register_window(surface, win)
  if valid_window(win) then
    window_surfaces[win] = surface
  end
end

local function unregister_window(win)
  if win ~= nil then
    window_surfaces[win] = nil
  end
end

local function repair_host(surface)
  if surface == nil
    or surface.closed
    or not valid_tab(surface.tab)
    or not valid_window(surface.host_win)
    or vim.api.nvim_win_get_tabpage(surface.host_win) ~= surface.tab
  then
    return false
  end
  local target = ensure_host_buffer()
  if vim.api.nvim_win_get_buf(surface.host_win) ~= target then
    local ok = pcall(vim.api.nvim_win_set_buf, surface.host_win, target)
    if not ok then
      return false
    end
  end
  register_window(surface, surface.host_win)
  return host_matches(surface)
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
  vim.w[win].phenix_sidebar_host = true
  vim.w[win].phenix_window_selectable = false
  vim.w[win].phenix_surface_id = nil
end

local function remember_cursor(surface)
  if surface ~= nil and valid_window(surface.compose_win) then
    local cursor = vim.api.nvim_win_get_cursor(surface.compose_win)
    surface.compose_cursor = cursor
    if surface == default_surface then
      state.remembered_compose_cursor = cursor
    end
  end
end

local function detach_children(surface)
  if surface == nil then
    return
  end
  winbar.detach(surface.transcript_win, surface.compose_win)
  compose.detach_window(surface.compose_win)
  transcript.detach_window(surface.transcript_win)
end

local function close_window(win)
  if valid_window(win) then
    pcall(vim.api.nvim_win_close, win, true)
  end
end

local function surface_open(surface)
  return surface ~= nil and not surface.closed and host_matches(surface)
end

local function open_surfaces(tab)
  local result = {}
  for _, surface in pairs(surfaces) do
    if surface.tab == tab and surface_open(surface) then
      table.insert(result, surface)
    end
  end
  table.sort(result, function(left, right)
    return left.id < right.id
  end)
  return result
end

local function fallback_surface(tab, exclude)
  local current = last_surface_by_tab[tab]
  if current ~= nil and current ~= exclude and surface_open(current) then
    return current
  end
  local visible = open_surfaces(tab)
  for index = #visible, 1, -1 do
    if visible[index] ~= exclude then
      return visible[index]
    end
  end
  return nil
end

local function remove_surface_view(surface, close_host)
  if surface == nil or surface.closing then
    return
  end
  surface.closing = true
  remember_cursor(surface)
  detach_children(surface)

  unregister_window(surface.compose_win)
  unregister_window(surface.transcript_win)
  unregister_window(surface.host_win)

  close_window(surface.compose_win)
  close_window(surface.transcript_win)
  if close_host then
    close_window(surface.host_win)
  end

  surface.compose_win = nil
  surface.transcript_win = nil
  surface.host_win = nil
  surface.closed = true
  surface.closing = false

  if last_surface_by_tab[surface.tab] == surface then
    last_surface_by_tab[surface.tab] = fallback_surface(surface.tab, surface) or surface
  end
end

local function geometry(surface)
  local width = math.max(1, vim.api.nvim_win_get_width(surface.host_win))
  local height = math.max(2, vim.api.nvim_win_get_height(surface.host_win))
  local requested_compose = math.max(1, math.floor(config.get().compose_height))
  local compose_height = math.min(requested_compose, height - 1)
  local transcript_height = math.max(1, height - compose_height)
  return {
    width = width,
    transcript_height = transcript_height,
    compose_height = compose_height,
  }
end

local function float_config(surface, role)
  local size = geometry(surface)
  local is_compose = role == "compose"
  return {
    relative = "win",
    win = surface.host_win,
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

local function ensure_float(surface, role, target)
  local field = role .. "_win"
  local win = surface[field]
  local expected = window_matches(win, surface.tab, target)
  if expected then
    pcall(vim.api.nvim_win_set_config, win, float_config(surface, role))
  else
    unregister_window(win)
    close_window(win)
    win = vim.api.nvim_open_win(target, false, float_config(surface, role))
    surface[field] = win
  end
  vim.w[win].phenix_sidebar_role = role
  vim.w[win].phenix_window_selectable = true
  vim.w[win].phenix_surface_id = surface.id
  register_window(surface, win)
  return win
end

local function current_surface_exact()
  local win = vim.api.nvim_get_current_win()
  local surface = window_surfaces[win]
  if surface ~= nil then
    return surface
  end
  return nil
end

local function install_window_actions(surface, target)
  local options = { buffer = target, silent = true }
  local function map(lhs, callback, desc)
    local opts = vim.tbl_extend("force", options, { desc = desc })
    vim.keymap.set("n", lhs, callback, opts)
  end

  map("<C-w>n", function()
    M.new_window(surface, "vertical")
  end, "Phenix: new chat window")
  map("<C-w>v", function()
    M.new_window(surface, "vertical")
  end, "Phenix: split to a new chat window")
  map("<C-w>s", function()
    M.new_window(surface, "horizontal")
  end, "Phenix: split below to a new chat window")
  map("<C-w>c", function()
    M.close_window(surface)
  end, "Phenix: close chat window")
  map("<C-w>q", function()
    M.close_window(surface)
  end, "Phenix: close chat window")

  local moves = {
    H = "H",
    J = "J",
    K = "K",
    L = "L",
    r = "r",
    R = "R",
    x = "x",
    o = "o",
    ["="] = "=",
    ["+"] = "+",
    ["-"] = "-",
    [">"] = ">",
    ["<"] = "<",
    ["_"] = "_",
    ["|"] = "|",
  }
  for key, command in pairs(moves) do
    map("<C-w>" .. key, function()
      M.host_wincmd(command, surface)
    end, "Phenix: apply window action to chat host")
  end
end

local function sync_surface(surface)
  if surface == nil or surface.closed or surface.closing or not repair_host(surface) then
    return false
  end

  apply_host_options(surface.host_win)
  transcript_controller.bind(surface.transcript_key, surface.session_id)

  local transcript_buffer = transcript.ensure(surface.transcript_key)
  local compose_buffer = compose.ensure(surface.compose)
  local transcript_win = ensure_float(surface, "transcript", transcript_buffer)
  local compose_win = ensure_float(surface, "compose", compose_buffer)

  transcript.attach_window(surface.transcript_key, transcript_win)
  compose.attach_window(surface.compose, compose_win)
  install_window_actions(surface, transcript_buffer)
  install_window_actions(surface, compose_buffer)
  winbar.attach(transcript_win, compose_win, surface)
  return true
end

local function focus_child(surface, role)
  if surface == nil
    or surface.closed
    or not valid_tab(surface.tab)
    or vim.api.nvim_get_current_tabpage() ~= surface.tab
  then
    return
  end
  local win = surface[role .. "_win"]
  if valid_window(win) then
    surface.selected_role = role
    last_surface_by_tab[surface.tab] = surface
    vim.api.nvim_set_current_win(win)
    if role == "compose" then
      pcall(vim.api.nvim_win_set_cursor, win, surface.compose_cursor)
    end
    if surface.session_id ~= nil then
      local status = runtime.status()
      if status.connection == "ready" and runtime.active_session() ~= surface.session_id then
        runtime.activate_session(surface.session_id)
      end
    end
  end
end

local function create_surface(tab, use_default)
  next_surface_id = next_surface_id + 1
  local surface = {
    id = next_surface_id,
    tab = tab,
    host_win = nil,
    transcript_win = nil,
    compose_win = nil,
    compose = use_default and state.compose or compose_model.new(),
    transcript_key = nil,
    session_id = use_default and runtime.active_session() or nil,
    compose_cursor = use_default and vim.deepcopy(state.remembered_compose_cursor) or { 1, 0 },
    selected_role = "compose",
    redirecting_host_focus = false,
    closing = false,
    moving = false,
    closed = true,
  }
  surface.transcript_key = use_default and transcript.default_key() or surface
  surfaces[surface.id] = surface
  if use_default then
    default_surface = surface
  end
  transcript_controller.bind(surface.transcript_key, surface.session_id)
  return surface
end

local function ensure_default_surface(tab)
  if default_surface == nil then
    return create_surface(tab, true)
  end
  if default_surface.tab == tab then
    return default_surface
  end
  local remembered = last_surface_by_tab[tab]
  if remembered ~= nil then
    return remembered
  end
  return create_surface(tab, false)
end

local function split_host(surface, source, command)
  local host
  source = valid_window(source) and source or vim.api.nvim_get_current_win()
  local ok = pcall(vim.api.nvim_win_call, source, function()
    vim.cmd(command)
    host = vim.api.nvim_get_current_win()
  end)
  if not ok or not valid_window(host) then
    return nil
  end
  surface.tab = vim.api.nvim_win_get_tabpage(host)
  surface.host_win = host
  surface.closed = false
  vim.api.nvim_win_set_buf(host, ensure_host_buffer())
  register_window(surface, host)
  apply_host_options(host)
  return host
end

local function open_surface(surface, options)
  options = options or {}
  if surface_open(surface) then
    sync_surface(surface)
    focus_child(surface, surface.selected_role or "compose")
    return surface
  end

  local command = options.command
  if command == nil then
    command = config.get().side == "left" and "topleft vsplit" or "botright vsplit"
  end
  local host = split_host(surface, options.source, command)
  if host == nil then
    return nil
  end
  if options.default_width ~= false then
    pcall(vim.api.nvim_win_set_width, host, sidebar_width(config.get().width))
  end
  last_surface_by_tab[surface.tab] = surface
  sync_surface(surface)
  focus_child(surface, "compose")
  return surface
end

local function redirect_host_focus(surface)
  if surface == nil or surface.closed or surface.closing or surface.moving or surface.redirecting_host_focus then
    return
  end
  surface.redirecting_host_focus = true
  vim.schedule(function()
    surface.redirecting_host_focus = false
    if surface.closed or not repair_host(surface) then
      return
    end
    if vim.api.nvim_get_current_win() ~= surface.host_win then
      return
    end
    if not sync_surface(surface) then
      remove_surface_view(surface, false)
      return
    end
    focus_child(surface, surface.selected_role or "compose")
  end)
end

function M.current_surface()
  local exact = current_surface_exact()
  if exact ~= nil then
    return exact
  end
  local tab = vim.api.nvim_get_current_tabpage()
  local remembered = last_surface_by_tab[tab]
  if remembered ~= nil then
    return remembered
  end
  local visible = open_surfaces(tab)
  return visible[#visible]
end

function M.surface_for_document(document)
  for _, surface in pairs(surfaces) do
    if surface.compose == document then
      return surface
    end
  end
  return nil
end

function M.open(surface)
  local tab = vim.api.nvim_get_current_tabpage()
  surface = surface or M.current_surface() or ensure_default_surface(tab)
  return open_surface(surface)
end

function M.new_window(origin, orientation)
  local tab = vim.api.nvim_get_current_tabpage()
  origin = origin or current_surface_exact() or M.current_surface()
  local source = origin and origin.host_win or vim.api.nvim_get_current_win()
  local surface = create_surface(tab, false)
  local horizontal = orientation == "horizontal"
  return open_surface(surface, {
    source = source,
    command = horizontal and "belowright split" or "rightbelow vsplit",
    default_width = false,
  })
end

function M.close_window(surface)
  surface = surface or current_surface_exact() or M.current_surface()
  if surface ~= nil then
    remove_surface_view(surface, true)
  end
end

function M.close()
  M.close_window()
end

function M.toggle()
  local exact = current_surface_exact()
  if exact ~= nil and surface_open(exact) then
    M.close_window(exact)
    return
  end
  local surface = M.current_surface()
  if surface ~= nil and surface_open(surface) then
    M.close_window(surface)
  else
    M.open()
  end
end

function M.host_wincmd(command, surface)
  surface = surface or current_surface_exact() or M.current_surface()
  if surface == nil or not surface_open(surface) then
    return false
  end

  local aliases = {
    left = "H",
    down = "J",
    up = "K",
    right = "L",
  }
  command = aliases[command] or command
  local allowed = {
    H = true,
    J = true,
    K = true,
    L = true,
    r = true,
    R = true,
    x = true,
    o = true,
    ["="] = true,
    ["+"] = true,
    ["-"] = true,
    [">"] = true,
    ["<"] = true,
    ["_"] = true,
    ["|"] = true,
  }
  if not allowed[command] then
    return false
  end

  remember_cursor(surface)
  surface.moving = true
  local ok = pcall(vim.api.nvim_win_call, surface.host_win, function()
    vim.cmd("wincmd " .. command)
  end)
  surface.moving = false
  if not ok then
    return false
  end

  vim.schedule(function()
    if surface_open(surface) and sync_surface(surface) then
      focus_child(surface, surface.selected_role or "compose")
    end
  end)
  return true
end

function M.move_window(direction, surface)
  return M.host_wincmd(direction, surface)
end

function M.focus_compose(surface)
  surface = M.open(surface)
  if surface == nil then
    return nil
  end
  focus_child(surface, "compose")
  return surface.compose_win, surface
end

function M.bind_session(session_id, surface)
  surface = surface or current_surface_exact() or M.current_surface()
  if surface == nil then
    surface = M.open()
  end
  if surface == nil then
    return nil
  end
  surface.session_id = session_id
  transcript_controller.bind(surface.transcript_key, session_id)
  winbar.refresh()
  return surface
end

function M.current_session()
  local surface = current_surface_exact() or M.current_surface()
  return surface and surface.session_id or nil
end

function M.current_compose()
  local surface = current_surface_exact() or M.current_surface()
  if surface == nil then
    surface = M.open()
  end
  return surface and surface.compose or state.compose
end

function M.remember_cursor()
  remember_cursor(current_surface_exact() or M.current_surface())
end

function M.buffers(surface)
  surface = surface or M.current_surface() or ensure_default_surface(vim.api.nvim_get_current_tabpage())
  return transcript.ensure(surface.transcript_key), compose.ensure(surface.compose)
end

function M.windows(surface)
  surface = surface or current_surface_exact() or M.current_surface()
  if surface == nil or not surface_open(surface) then
    return nil, nil, nil
  end
  if not sync_surface(surface) then
    remove_surface_view(surface, false)
    return nil, nil, nil
  end
  return surface.transcript_win, surface.compose_win, surface.host_win
end

function M.is_open()
  local surface = current_surface_exact() or M.current_surface()
  return surface_open(surface)
end

function M.is_host(win)
  win = win or vim.api.nvim_get_current_win()
  local surface = window_surfaces[win]
  return surface ~= nil and surface.host_win == win and surface_open(surface)
end

function M.is_selectable(win)
  return valid_window(win) and not M.is_host(win)
end

function M.list_surfaces(tab)
  tab = tab or vim.api.nvim_get_current_tabpage()
  local result = {}
  for _, surface in pairs(surfaces) do
    if surface.tab == tab then
      table.insert(result, surface)
    end
  end
  table.sort(result, function(left, right)
    return left.id < right.id
  end)
  return result
end

vim.api.nvim_create_autocmd("WinClosed", {
  group = group,
  callback = function(args)
    local closed = tonumber(args.match)
    if closed == nil then
      return
    end
    local surface = window_surfaces[closed]
    unregister_window(closed)
    if surface == nil or surface.closing then
      return
    end
    vim.schedule(function()
      if not surface.closed and not surface.closing then
        remove_surface_view(surface, true)
      end
    end)
  end,
})

vim.api.nvim_create_autocmd("BufWinEnter", {
  group = group,
  callback = function()
    local tab = vim.api.nvim_get_current_tabpage()
    vim.schedule(function()
      for _, surface in ipairs(open_surfaces(tab)) do
        if not surface.closing then
          if not repair_host(surface) then
            remove_surface_view(surface, false)
          else
            sync_surface(surface)
          end
        end
      end
    end)
  end,
})

vim.api.nvim_create_autocmd("TabLeave", {
  group = group,
  callback = function()
    local tab = vim.api.nvim_get_current_tabpage()
    for _, surface in ipairs(open_surfaces(tab)) do
      remember_cursor(surface)
      compose.detach_window(surface.compose_win)
    end
  end,
})

vim.api.nvim_create_autocmd("TabEnter", {
  group = group,
  callback = function()
    local tab = vim.api.nvim_get_current_tabpage()
    vim.schedule(function()
      for _, surface in ipairs(open_surfaces(tab)) do
        sync_surface(surface)
      end
    end)
  end,
})

vim.api.nvim_create_autocmd("WinEnter", {
  group = group,
  callback = function()
    local win = vim.api.nvim_get_current_win()
    local surface = window_surfaces[win]
    if surface == nil or surface.closed or surface.closing then
      return
    end
    if win == surface.transcript_win then
      surface.selected_role = "transcript"
      last_surface_by_tab[surface.tab] = surface
      if surface.session_id ~= nil and runtime.status().connection == "ready" then
        runtime.activate_session(surface.session_id)
      end
      return
    end
    if win == surface.compose_win then
      surface.selected_role = "compose"
      last_surface_by_tab[surface.tab] = surface
      if surface.session_id ~= nil and runtime.status().connection == "ready" then
        runtime.activate_session(surface.session_id)
      end
      return
    end
    if win == surface.host_win then
      redirect_host_focus(surface)
    end
  end,
})

vim.api.nvim_create_autocmd({ "VimResized", "WinResized" }, {
  group = group,
  callback = function()
    vim.schedule(function()
      for _, surface in pairs(surfaces) do
        if surface_open(surface) and not surface.closing then
          if not sync_surface(surface) then
            remove_surface_view(surface, false)
          end
        end
      end
    end)
  end,
})

return M
