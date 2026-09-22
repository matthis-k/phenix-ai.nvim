local M = {}
local namespace = vim.api.nvim_create_namespace("phenix-transcript")
local style_namespace = vim.api.nvim_create_namespace("phenix-transcript-style")
local group = vim.api.nvim_create_augroup("phenix-transcript-view", { clear = true })
local default_key = {}
local stores = setmetatable({}, { __mode = "k" })
local next_buffer_id = 0
local window_keys = {}

local function view_key(key)
  return key or default_key
end

local function store(key)
  key = view_key(key)
  local value = stores[key]
  if value == nil then
    value = {
      key = key,
      buffer = nil,
      marks = {},
      attached_windows = {},
      last_projection = nil,
    }
    stores[key] = value
  end
  return value
end

function M.default_key()
  return default_key
end

local function inspect(value)
  if value == nil then
    return nil
  end
  if type(value) == "string" then
    return value
  end
  return vim.inspect(value)
end

local function text_lines(text)
  local lines = vim.split(tostring(text or ""), "\n", { plain = true })
  return #lines > 0 and lines or { "" }
end

local function append(lines, values)
  for _, value in ipairs(values) do
    table.insert(lines, value)
  end
end

local function lines_for(node)
  if node.kind == "message" then
    local lines = { node.role == "user" and "You" or "Assistant", "" }
    append(lines, text_lines(node.text))
    table.insert(lines, "")
    return lines
  end
  if node.kind == "tool" then
    local title = "Tool · " .. tostring(node.callable_id or "unknown") .. " · " .. tostring(node.state or "running")
    local lines = { title }
    local input = inspect(node.input)
    if input ~= nil and input ~= "" then
      table.insert(lines, "")
      table.insert(lines, "Input")
      append(lines, text_lines(input))
    end
    local output = inspect(node.output)
    if output ~= nil and output ~= "" then
      table.insert(lines, "")
      table.insert(lines, node.state == "failed" and "Error" or "Output")
      append(lines, text_lines(output))
    end
    table.insert(lines, "")
    return lines
  end
  if node.kind == "execution" then
    local label = node.message or node.state or "running"
    if node.fraction ~= nil then
      label = string.format("%s · %.0f%%", label, node.fraction * 100)
    end
    return { "· " .. label, "" }
  end
  if node.kind == "diagnostic" then
    local prefix = node.severity and (string.upper(node.severity) .. " · ") or ""
    return { prefix .. tostring(node.message or node.code or "diagnostic"), "" }
  end
  if node.kind == "review" then
    local review = node.review or {}
    local state = review.state and review.state.kind or "Pending"
    return { "Review · " .. tostring(state), "" }
  end
  return { vim.inspect(node), "" }
end

local function buffer_name()
  next_buffer_id = next_buffer_id + 1
  if next_buffer_id == 1 then
    return "phenix://transcript"
  end
  return "phenix://transcript/" .. tostring(next_buffer_id)
end

function M.ensure(key)
  local view = store(key)
  if view.buffer ~= nil and vim.api.nvim_buf_is_valid(view.buffer) then
    return view.buffer
  end
  view.buffer = vim.api.nvim_create_buf(false, true)
  vim.bo[view.buffer].buftype = "nofile"
  vim.bo[view.buffer].bufhidden = "hide"
  vim.bo[view.buffer].modifiable = false
  vim.bo[view.buffer].swapfile = false
  vim.bo[view.buffer].filetype = "markdown"
  vim.bo[view.buffer].undolevels = -1
  vim.api.nvim_buf_set_name(view.buffer, buffer_name())
  view.marks = {}
  view.attached_windows = {}
  if view.last_projection ~= nil and type(M.render_projection) == "function" then
    M.render_projection(view.last_projection, key)
  end
  return view.buffer
end

local function valid_window(win, key)
  return win ~= nil
    and vim.api.nvim_win_is_valid(win)
    and vim.api.nvim_win_get_buf(win) == M.ensure(key)
end

local function visible_bottom(win)
  local ok, line = pcall(vim.api.nvim_win_call, win, function()
    return vim.fn.line("w$")
  end)
  return ok and line or 0
end

local function update_follow_tail(win)
  local key = window_keys[win]
  if key == nil then
    return
  end
  local view = stores[key]
  local state = view and view.attached_windows[win] or nil
  if state == nil then
    window_keys[win] = nil
    return
  end
  if not valid_window(win, key) then
    view.attached_windows[win] = nil
    window_keys[win] = nil
    return
  end
  state.follow_tail = visible_bottom(win) >= vim.api.nvim_buf_line_count(M.ensure(key))
end

local function scroll_to_tail(key)
  local view = store(key)
  local last = math.max(vim.api.nvim_buf_line_count(M.ensure(key)), 1)
  for win, state in pairs(view.attached_windows) do
    if valid_window(win, key) then
      if state.follow_tail then
        pcall(vim.api.nvim_win_set_cursor, win, { last, 0 })
      end
    else
      view.attached_windows[win] = nil
      window_keys[win] = nil
    end
  end
end

function M.attach_window(key, win)
  if win == nil then
    win = key
    key = nil
  end
  local resolved = view_key(key)
  local view = store(resolved)
  if not valid_window(win, resolved) then
    return
  end
  if view.attached_windows[win] == nil then
    view.attached_windows[win] = { follow_tail = true }
  end
  window_keys[win] = resolved
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].breakindent = true
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].foldcolumn = "0"
  vim.wo[win].cursorline = false
  vim.wo[win].winfixwidth = true
  vim.wo[win].conceallevel = 2
  update_follow_tail(win)
end

function M.detach_window(win)
  local key = window_keys[win]
  if key == nil then
    return
  end
  local view = stores[key]
  if view ~= nil then
    view.attached_windows[win] = nil
  end
  window_keys[win] = nil
end

function M.set_follow_tail(enabled, win, key)
  win = win or vim.api.nvim_get_current_win()
  key = key or window_keys[win]
  local view = store(key)
  local state = view.attached_windows[win]
  if state == nil then
    for _, candidate in pairs(view.attached_windows) do
      candidate.follow_tail = enabled == true
    end
  else
    state.follow_tail = enabled == true
  end
  if enabled then
    scroll_to_tail(key)
  end
end

function M.is_following_tail(win, key)
  win = win or vim.api.nvim_get_current_win()
  key = key or window_keys[win]
  local view = store(key)
  local state = view.attached_windows[win]
  if state ~= nil then
    return state.follow_tail
  end
  for _, candidate in pairs(view.attached_windows) do
    return candidate.follow_tail
  end
  return false
end

local function replace(view, start_row, finish_row, lines)
  local target = M.ensure(view.key)
  vim.bo[target].modifiable = true
  vim.api.nvim_buf_set_lines(target, start_row, finish_row, false, lines)
  vim.bo[target].modifiable = false
end

local function style_node(view, node, start_row, lines)
  local target = M.ensure(view.key)
  vim.api.nvim_buf_clear_namespace(target, style_namespace, start_row, start_row + math.max(#lines, 1))
  local group_name = "Comment"
  if node.kind == "message" then
    group_name = node.role == "user" and "Title" or "Special"
  elseif node.kind == "tool" then
    group_name = node.state == "failed" and "DiagnosticError" or "Identifier"
  elseif node.kind == "diagnostic" then
    group_name = node.severity == "error" and "DiagnosticError" or "DiagnosticWarn"
  elseif node.kind == "review" then
    group_name = "DiagnosticInfo"
  end
  vim.api.nvim_buf_add_highlight(target, style_namespace, group_name, start_row, 0, -1)
end

function M.render_node(node, key)
  local view = store(key)
  local target = M.ensure(key)
  local existing = view.marks[node.id]
  local lines = lines_for(node)
  local start_row
  if existing ~= nil then
    local position = vim.api.nvim_buf_get_extmark_by_id(target, namespace, existing, { details = true })
    if #position == 0 then
      view.marks[node.id] = nil
      return M.render_node(node, key)
    end
    start_row = position[1]
    local finish_row = (position[3].end_row or position[1]) + 1
    replace(view, start_row, finish_row, lines)
  else
    start_row = vim.api.nvim_buf_line_count(target)
    if start_row == 1 and vim.api.nvim_buf_get_lines(target, 0, 1, false)[1] == "" then
      start_row = 0
      replace(view, 0, 1, lines)
    else
      replace(view, start_row, start_row, lines)
    end
  end
  local end_row = start_row + math.max(#lines - 1, 0)
  view.marks[node.id] = vim.api.nvim_buf_set_extmark(target, namespace, start_row, 0, {
    id = existing,
    end_row = end_row,
    end_col = #(lines[#lines] or ""),
    right_gravity = false,
  })
  style_node(view, node, start_row, lines)
  scroll_to_tail(key)
end

function M.remember_projection(projection, key)
  store(key).last_projection = vim.deepcopy(projection)
end

function M.render_projection(projection, key)
  local view = store(key)
  M.remember_projection(projection, key)
  local target = M.ensure(key)
  vim.bo[target].modifiable = true
  vim.api.nvim_buf_set_lines(target, 0, -1, false, {})
  vim.api.nvim_buf_clear_namespace(target, namespace, 0, -1)
  vim.api.nvim_buf_clear_namespace(target, style_namespace, 0, -1)
  vim.bo[target].modifiable = false
  view.marks = {}
  for _, id in ipairs(projection.order) do
    M.render_node(projection.nodes[id], key)
  end
  scroll_to_tail(key)
end

vim.api.nvim_create_autocmd("WinScrolled", {
  group = group,
  callback = function(args)
    local win = tonumber(args.match)
    if win ~= nil and window_keys[win] ~= nil then
      update_follow_tail(win)
    end
  end,
})

vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
  group = group,
  callback = function()
    local win = vim.api.nvim_get_current_win()
    if window_keys[win] ~= nil then
      update_follow_tail(win)
    end
  end,
})

vim.api.nvim_create_autocmd("WinClosed", {
  group = group,
  callback = function(args)
    local win = tonumber(args.match)
    if win ~= nil then
      M.detach_window(win)
    end
  end,
})

return M
