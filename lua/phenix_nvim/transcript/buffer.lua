local M = {}
local namespace = vim.api.nvim_create_namespace("phenix-transcript")
local style_namespace = vim.api.nvim_create_namespace("phenix-transcript-style")
local group = vim.api.nvim_create_augroup("phenix-transcript-view", { clear = true })
local buffer
local marks = {}
local attached_windows = {}
local last_projection

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

function M.ensure()
  if buffer ~= nil and vim.api.nvim_buf_is_valid(buffer) then
    return buffer
  end
  buffer = vim.api.nvim_create_buf(false, true)
  vim.bo[buffer].buftype = "nofile"
  vim.bo[buffer].bufhidden = "hide"
  vim.bo[buffer].modifiable = false
  vim.bo[buffer].swapfile = false
  vim.bo[buffer].filetype = "markdown"
  vim.bo[buffer].undolevels = -1
  vim.api.nvim_buf_set_name(buffer, "phenix://transcript")
  marks = {}
  attached_windows = {}
  if last_projection ~= nil and type(M.render_projection) == "function" then
    M.render_projection(last_projection)
  end
  return buffer
end

local function valid_window(win)
  return win ~= nil
    and vim.api.nvim_win_is_valid(win)
    and vim.api.nvim_win_get_buf(win) == M.ensure()
end

local function visible_bottom(win)
  local ok, line = pcall(vim.api.nvim_win_call, win, function()
    return vim.fn.line("w$")
  end)
  return ok and line or 0
end

local function update_follow_tail(win)
  local view = attached_windows[win]
  if view == nil then
    return
  end
  if not valid_window(win) then
    attached_windows[win] = nil
    return
  end
  view.follow_tail = visible_bottom(win) >= vim.api.nvim_buf_line_count(M.ensure())
end

local function scroll_to_tail()
  local last = math.max(vim.api.nvim_buf_line_count(M.ensure()), 1)
  for win, view in pairs(attached_windows) do
    if valid_window(win) then
      if view.follow_tail then
        pcall(vim.api.nvim_win_set_cursor, win, { last, 0 })
      end
    else
      attached_windows[win] = nil
    end
  end
end

function M.attach_window(win)
  if not valid_window(win) then
    return
  end
  if attached_windows[win] == nil then
    attached_windows[win] = { follow_tail = true }
  end
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
  attached_windows[win] = nil
end

function M.set_follow_tail(enabled, win)
  win = win or vim.api.nvim_get_current_win()
  local view = attached_windows[win]
  if view == nil then
    for _, candidate in pairs(attached_windows) do
      candidate.follow_tail = enabled == true
    end
  else
    view.follow_tail = enabled == true
  end
  if enabled then
    scroll_to_tail()
  end
end

function M.is_following_tail(win)
  win = win or vim.api.nvim_get_current_win()
  local view = attached_windows[win]
  if view ~= nil then
    return view.follow_tail
  end
  for _, candidate in pairs(attached_windows) do
    return candidate.follow_tail
  end
  return false
end

local function replace(start_row, finish_row, lines)
  local target = M.ensure()
  vim.bo[target].modifiable = true
  vim.api.nvim_buf_set_lines(target, start_row, finish_row, false, lines)
  vim.bo[target].modifiable = false
end

local function style_node(node, start_row, lines)
  local target = M.ensure()
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

function M.render_node(node)
  local target = M.ensure()
  local existing = marks[node.id]
  local lines = lines_for(node)
  local start_row
  if existing ~= nil then
    local position = vim.api.nvim_buf_get_extmark_by_id(target, namespace, existing, { details = true })
    if #position == 0 then
      marks[node.id] = nil
      return M.render_node(node)
    end
    start_row = position[1]
    local finish_row = (position[3].end_row or position[1]) + 1
    replace(start_row, finish_row, lines)
  else
    start_row = vim.api.nvim_buf_line_count(target)
    if start_row == 1 and vim.api.nvim_buf_get_lines(target, 0, 1, false)[1] == "" then
      start_row = 0
      replace(0, 1, lines)
    else
      replace(start_row, start_row, lines)
    end
  end
  local end_row = start_row + math.max(#lines - 1, 0)
  marks[node.id] = vim.api.nvim_buf_set_extmark(target, namespace, start_row, 0, {
    id = existing,
    end_row = end_row,
    end_col = #(lines[#lines] or ""),
    right_gravity = false,
  })
  style_node(node, start_row, lines)
  scroll_to_tail()
end

function M.remember_projection(projection)
  last_projection = vim.deepcopy(projection)
end

function M.render_projection(projection)
  M.remember_projection(projection)
  local target = M.ensure()
  vim.bo[target].modifiable = true
  vim.api.nvim_buf_set_lines(target, 0, -1, false, {})
  vim.api.nvim_buf_clear_namespace(target, namespace, 0, -1)
  vim.api.nvim_buf_clear_namespace(target, style_namespace, 0, -1)
  vim.bo[target].modifiable = false
  marks = {}
  for _, id in ipairs(projection.order) do
    M.render_node(projection.nodes[id])
  end
  scroll_to_tail()
end

vim.api.nvim_create_autocmd("WinScrolled", {
  group = group,
  callback = function(args)
    local win = tonumber(args.match)
    if win ~= nil and attached_windows[win] ~= nil then
      update_follow_tail(win)
    end
  end,
})

vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
  group = group,
  callback = function()
    local win = vim.api.nvim_get_current_win()
    if attached_windows[win] ~= nil then
      update_follow_tail(win)
    end
  end,
})

vim.api.nvim_create_autocmd("WinClosed", {
  group = group,
  callback = function(args)
    local win = tonumber(args.match)
    if win ~= nil then
      attached_windows[win] = nil
    end
  end,
})

return M
