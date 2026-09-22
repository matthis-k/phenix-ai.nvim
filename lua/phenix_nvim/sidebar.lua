local config = require("phenix_nvim.config")
local state = require("phenix_nvim.state")
local runtime = require("phenix_nvim.runtime")
local compose = require("phenix_nvim.compose.buffer")
local transcript = require("phenix_nvim.transcript.buffer")
local transcript_controller = require("phenix_nvim.transcript.controller")
local winbar = require("phenix_nvim.winbar")

local M = {}
local group = vim.api.nvim_create_augroup("phenix-sidebar", { clear = true })
local surfaces = {}
local hosts = {}
local children = {}
local next_surface_id = 0
local reconciling = false
local primary_states = {}
local primary_compose_claimed = false

local function valid_window(win)
  return win ~= nil and vim.api.nvim_win_is_valid(win)
end

local function valid_tab(tab)
  return tab ~= nil and vim.api.nvim_tabpage_is_valid(tab)
end

local function surface_buffer_name(surface)
  return "phenix://chat/" .. tostring(surface.id)
end

local function ensure_host_buffer(surface)
  if surface.host_buffer ~= nil and vim.api.nvim_buf_is_valid(surface.host_buffer) then
    return surface.host_buffer
  end
  local target = vim.api.nvim_create_buf(false, true)
  surface.host_buffer = target
  vim.bo[target].buftype = "nofile"
  vim.bo[target].bufhidden = "hide"
  vim.bo[target].swapfile = false
  vim.bo[target].modifiable = false
  vim.bo[target].filetype = "phenix-sidebar"
  vim.b[target].phenix_internal = true
  vim.b[target].phenix_role = "host"
  vim.b[target].phenix_surface_id = surface.id
  vim.api.nvim_buf_set_name(target, surface_buffer_name(surface))
  return target
end

local function window_matches(win, surface, target)
  return valid_window(win)
    and valid_tab(surface.tab)
    and vim.api.nvim_win_get_tabpage(win) == surface.tab
    and vim.api.nvim_win_get_buf(win) == target
end

local function host_matches(surface)
  return window_matches(surface.host_win, surface, ensure_host_buffer(surface))
end

local function repair_host(surface)
  if surface == nil
    or surface.closing
    or not valid_tab(surface.tab)
    or not valid_window(surface.host_win)
    or vim.api.nvim_win_get_tabpage(surface.host_win) ~= surface.tab
  then
    return false
  end
  local target = ensure_host_buffer(surface)
  if vim.api.nvim_win_get_buf(surface.host_win) ~= target then
    local ok = pcall(vim.api.nvim_win_set_buf, surface.host_win, target)
    if not ok then
      return false
    end
  end
  return host_matches(surface)
end

local function sidebar_width(value)
  if value <= 1 then
    return math.max(20, math.floor(vim.o.columns * value))
  end
  return math.max(1, math.floor(value))
end

local function apply_host_options(surface)
  local win = surface.host_win
  if not valid_window(win) then
    return
  end
  vim.wo[win].winfixwidth = false
  vim.wo[win].wrap = false
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].foldcolumn = "0"
  vim.wo[win].cursorline = false
  vim.wo[win].winbar = ""
  vim.wo[win].statusline = " "
  vim.w[win].phenix_sidebar_host = true
  vim.w[win].phenix_surface_id = surface.id
  vim.w[win].phenix_window_selectable = false
end

local function remember_cursor(surface)
  if surface ~= nil and valid_window(surface.compose_win) then
    surface.state.compose_cursor = vim.api.nvim_win_get_cursor(surface.compose_win)
  end
end

local function detach_children(surface)
  if surface == nil then
    return
  end
  winbar.detach(surface.transcript_win, surface.compose_win)
  compose.detach_window(surface.compose_win)
  transcript.detach_window(surface.transcript_win)
  children[surface.transcript_win] = nil
  children[surface.compose_win] = nil
end

local function close_window(win)
  if valid_window(win) then
    pcall(vim.api.nvim_win_close, win, true)
  end
end

local function unregister(surface)
  surfaces[surface.id] = nil
  hosts[surface.host_win] = nil
  children[surface.transcript_win] = nil
  children[surface.compose_win] = nil
end

local function close_surface(surface, close_host)
  if surface == nil or surface.closing then
    return
  end
  surface.closing = true
  remember_cursor(surface)
  detach_children(surface)
  close_window(surface.compose_win)
  close_window(surface.transcript_win)
  if close_host then
    close_window(surface.host_win)
  end
  unregister(surface)
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
  if window_matches(win, surface, target) then
    pcall(vim.api.nvim_win_set_config, win, float_config(surface, role))
    vim.w[win].phenix_sidebar_role = role
    vim.w[win].phenix_surface_id = surface.id
    vim.w[win].phenix_window_selectable = true
    children[win] = surface
    return win
  end

  children[win] = nil
  close_window(win)
  win = vim.api.nvim_open_win(target, false, float_config(surface, role))
  surface[field] = win
  children[win] = surface
  vim.w[win].phenix_sidebar_role = role
  vim.w[win].phenix_surface_id = surface.id
  vim.w[win].phenix_window_selectable = true
  return win
end

local function sync_surface(surface)
  if surface == nil or surface.closing or not repair_host(surface) then
    return false
  end
  apply_host_options(surface)
  transcript_controller.bind(surface.transcript_key, surface.state.session_id)
  local transcript_win = ensure_float(surface, "transcript", transcript.ensure(surface.transcript_key))
  local compose_win = ensure_float(surface, "compose", compose.ensure(surface.state.compose))
  transcript.attach_window(surface.transcript_key, transcript_win)
  compose.attach_window(surface.state.compose, compose_win)
  winbar.attach(transcript_win, compose_win, surface)
  local function map_children(key, callback, description)
    for _, win in ipairs({ transcript_win, compose_win }) do
      vim.keymap.set("n", key, callback, {
        buffer = vim.api.nvim_win_get_buf(win),
        silent = true,
        desc = description,
      })
    end
  end

  map_children("<C-w>n", function()
    M.new_window(surface, { command = "rightbelow vsplit" })
  end, "Open a new Phenix chat beside this one")
  map_children("<C-w>v", function()
    M.new_window(surface, { command = "rightbelow vsplit" })
  end, "Open a new Phenix chat beside this one")
  map_children("<C-w>s", function()
    M.new_window(surface, { command = "rightbelow split" })
  end, "Open a new Phenix chat below this one")

  for key, direction in pairs({
    ["<C-w>H"] = "left",
    ["<C-w>L"] = "right",
    ["<C-w>K"] = "up",
    ["<C-w>J"] = "down",
    ["<C-w>T"] = "tab",
  }) do
    map_children(key, function()
      M.move_window(direction, surface)
    end, "Move Phenix chat " .. direction)
  end

  for key, command in pairs({
    ["<C-w>r"] = "wincmd r",
    ["<C-w>R"] = "wincmd R",
    ["<C-w>x"] = "wincmd x",
    ["<C-w>="] = "wincmd =",
    ["<C-w>+"] = "wincmd +",
    ["<C-w>-"] = "wincmd -",
    ["<C-w><"] = "wincmd <",
    ["<C-w>>"] = "wincmd >",
  }) do
    map_children(key, function()
      M.host_command(command, surface)
    end, "Apply window operation to Phenix chat host")
  end
  return true
end

local function reconcile_surface(surface)
  if surface == nil or surface.closing then
    return nil
  end
  if not repair_host(surface) or not sync_surface(surface) then
    close_surface(surface, false)
    return nil
  end
  return surface
end

local function focus_child(surface, role)
  if surface == nil or not valid_tab(surface.tab) or vim.api.nvim_get_current_tabpage() ~= surface.tab then
    return
  end
  local win = surface[role .. "_win"]
  if valid_window(win) then
    surface.selected_role = role
    runtime.activate_session(surface.session_id)
    vim.api.nvim_set_current_win(win)
    if role == "compose" then
      pcall(vim.api.nvim_win_set_cursor, win, surface.state.compose_cursor)
    end
  end
end

local function surface_for_window(win)
  return hosts[win] or children[win]
end

local function current_surface()
  local win = vim.api.nvim_get_current_win()
  local direct = surface_for_window(win)
  if direct ~= nil and not direct.closing then
    return direct
  end
  local tab = vim.api.nvim_get_current_tabpage()
  local found
  for _, surface in pairs(surfaces) do
    if not surface.closing and surface.tab == tab then
      if found ~= nil then
        return nil
      end
      found = surface
    end
  end
  return found
end

local function redirect_host_focus(surface)
  if surface == nil or surface.closing or surface.redirecting_host_focus then
    return
  end
  surface.redirecting_host_focus = true
  vim.schedule(function()
    surface.redirecting_host_focus = false
    if surfaces[surface.id] ~= surface or not repair_host(surface) then
      return
    end
    if vim.api.nvim_get_current_win() ~= surface.host_win then
      return
    end
    if not sync_surface(surface) then
      close_surface(surface, false)
      return
    end
    focus_child(surface, surface.selected_role or "compose")
  end)
end

local function primary_state(tab)
  local value = primary_states[tab]
  if value == nil then
    if not primary_compose_claimed then
      primary_compose_claimed = true
      value = {
        session_id = nil,
        compose = state.compose,
        compose_cursor = vim.deepcopy(state.remembered_compose_cursor),
        transcript_key = transcript.default_key(),
      }
    else
      value = state.new_surface()
    end
    primary_states[tab] = value
  end
  return value
end

local function create_surface(host_win, surface_state)
  next_surface_id = next_surface_id + 1
  local surface = {
    id = next_surface_id,
    tab = vim.api.nvim_win_get_tabpage(host_win),
    host_win = host_win,
    host_buffer = nil,
    transcript_win = nil,
    compose_win = nil,
    state = surface_state or state.new_surface(),
    selected_role = "compose",
    redirecting_host_focus = false,
    closing = false,
  }
  vim.api.nvim_win_set_buf(host_win, ensure_host_buffer(surface))
  surface.compose = surface.state.compose
  surface.session_id = surface.state.session_id
  surface.transcript_key = surface.state.transcript_key or surface
  surfaces[surface.id] = surface
  hosts[host_win] = surface
  apply_host_options(surface)
  sync_surface(surface)
  return surface
end

local function create_default_host()
  local options = config.get()
  vim.cmd(options.side == "left" and "topleft vsplit" or "botright vsplit")
  local host = vim.api.nvim_get_current_win()
  pcall(vim.api.nvim_win_set_width, host, sidebar_width(options.width))
  return host
end

function M.is_open()
  return current_surface() ~= nil
end

function M.current()
  return current_surface()
end

function M.current_surface()
  return current_surface()
end

function M.surface_for_document(document)
  for _, surface in pairs(surfaces) do
    if not surface.closing and surface.compose == document then
      return surface
    end
  end
  return nil
end

function M.surface_for_window(win)
  return surface_for_window(win or vim.api.nvim_get_current_win())
end

function M.remember_cursor()
  remember_cursor(current_surface())
end

function M.open()
  local surface = current_surface()
  if surface ~= nil and reconcile_surface(surface) ~= nil then
    winbar.refresh()
    focus_child(surface, "compose")
    return surface
  end

  local tab = vim.api.nvim_get_current_tabpage()
  local surface_state = primary_state(tab)
  if surface_state.session_id == nil then
    surface_state.session_id = runtime.active_session()
  end
  surface = create_surface(create_default_host(), surface_state)
  focus_child(surface, "compose")
  return surface
end

function M.new_window(origin, options)
  if type(origin) ~= "table" or origin.host_win == nil then
    options = origin or options or {}
    origin = current_surface()
  else
    options = options or {}
  end
  local origin_host = origin and origin.host_win or vim.api.nvim_get_current_win()
  local command = options.command or "rightbelow vsplit"
  local host
  vim.api.nvim_win_call(origin_host, function()
    vim.cmd(command)
    host = vim.api.nvim_get_current_win()
  end)
  local surface = create_surface(host)
  if options.session_id ~= nil then
    surface.state.session_id = options.session_id
    sync_surface(surface)
  end
  focus_child(surface, "compose")
  return surface
end

function M.close()
  close_surface(current_surface(), true)
end

function M.close_window()
  M.close()
end

function M.host_command(command, surface)
  surface = surface or current_surface()
  if surface == nil or type(command) ~= "string" or command == "" then
    return nil
  end
  vim.api.nvim_win_call(surface.host_win, function()
    vim.cmd(command)
  end)
  if valid_window(surface.host_win) then
    surface.tab = vim.api.nvim_win_get_tabpage(surface.host_win)
  end
  sync_surface(surface)
  M.reconcile()
  return true
end

function M.move_window(direction, surface)
  surface = surface or current_surface()
  if surface == nil then
    return nil
  end
  local commands = {
    left = "wincmd H",
    right = "wincmd L",
    up = "wincmd K",
    down = "wincmd J",
    top = "wincmd K",
    bottom = "wincmd J",
    tab = "wincmd T",
  }
  local command = commands[direction]
  if command == nil then
    return nil
  end
  return M.host_command(command, surface)
end

function M.toggle()
  local surface = current_surface()
  if surface ~= nil then
    close_surface(surface, true)
  else
    M.open()
  end
end

function M.focus_compose(target)
  local surface = type(target) == "table" and target.id ~= nil and target or current_surface()
  local document = type(target) == "table" and target.id == nil and target or nil
  if document ~= nil and (surface == nil or surface.state.compose ~= document) then
    for _, candidate in pairs(surfaces) do
      if candidate.state.compose == document then
        surface = candidate
        break
      end
    end
  end
  if surface == nil then
    M.open()
    surface = current_surface()
  end
  reconcile_surface(surface)
  focus_child(surface, "compose")
  return surface and surface.compose_win or nil
end

function M.bind_session(session_id, surface)
  surface = surface or current_surface()
  if surface == nil then
    return nil
  end
  surface.state.session_id = session_id
  surface.session_id = session_id
  transcript_controller.bind(surface.transcript_key, session_id)
  sync_surface(surface)
  return surface
end

function M.current_compose()
  local surface = current_surface()
  return surface and surface.compose or state.compose
end

function M.buffers(surface)
  surface = surface or current_surface()
  if surface == nil then
    return transcript.ensure(), compose.ensure(state.compose)
  end
  return transcript.ensure(surface.transcript_key), compose.ensure(surface.state.compose)
end

function M.windows(surface)
  surface = surface or current_surface()
  if surface == nil or reconcile_surface(surface) == nil then
    return nil, nil, nil
  end
  return surface.transcript_win, surface.compose_win, surface.host_win
end

function M.is_host(win)
  return hosts[win or vim.api.nvim_get_current_win()] ~= nil
end

function M.is_selectable(win)
  return valid_window(win) and not M.is_host(win)
end

function M.reconcile()
  if reconciling then
    return
  end
  reconciling = true
  vim.schedule(function()
    reconciling = false
    local ids = {}
    for id in pairs(surfaces) do
      table.insert(ids, id)
    end
    for _, id in ipairs(ids) do
      local live = surfaces[id]
      if live ~= nil and not live.closing then
        if not valid_tab(live.tab) or not repair_host(live) then
          close_surface(live, false)
        else
          sync_surface(live)
        end
      end
    end
  end)
end

vim.api.nvim_create_autocmd("WinClosed", {
  group = group,
  callback = function(args)
    local closed = tonumber(args.match)
    if closed == nil then
      return
    end
    local surface = surface_for_window(closed)
    if surface == nil or surface.closing then
      return
    end
    vim.schedule(function()
      if surfaces[surface.id] == surface then
        -- A Phenix chat is an atomic surface. Closing either child is semantically
        -- the same action as closing its reservation host.
        close_surface(surface, closed ~= surface.host_win)
      end
    end)
  end,
})

vim.api.nvim_create_autocmd({ "BufWinLeave", "WinNew", "WinResized", "VimResized" }, {
  group = group,
  callback = M.reconcile,
})

vim.api.nvim_create_autocmd("TabLeave", {
  group = group,
  callback = function()
    local tab = vim.api.nvim_get_current_tabpage()
    for _, surface in pairs(surfaces) do
      if surface.tab == tab and not surface.closing then
        remember_cursor(surface)
        compose.detach_window(surface.compose_win)
      end
    end
  end,
})

vim.api.nvim_create_autocmd("TabEnter", {
  group = group,
  callback = M.reconcile,
})

vim.api.nvim_create_autocmd("WinEnter", {
  group = group,
  callback = function()
    local win = vim.api.nvim_get_current_win()
    local surface = surface_for_window(win)
    if surface == nil or surface.closing then
      M.reconcile()
      return
    end
    if win == surface.host_win then
      redirect_host_focus(surface)
      return
    end
    if win == surface.transcript_win then
      surface.selected_role = "transcript"
      runtime.activate_session(surface.session_id)
    elseif win == surface.compose_win then
      surface.selected_role = "compose"
      runtime.activate_session(surface.session_id)
    end
  end,
})

return M
