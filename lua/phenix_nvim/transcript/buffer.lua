local disclosure = require("phenix_nvim.disclosure")
local tool_view = require("phenix_nvim.transcript.tool_view")

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
      name = nil,
      marks = {},
      attached_windows = {},
      disclosure = disclosure.new(),
      tool_modes = {},
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

local function lines_for(view, node)
  if node.kind == "message" then
    local lines = { node.role == "user" and "You" or "Assistant", "" }
    append(lines, text_lines(node.text))
    table.insert(lines, "")
    return lines
  end
  if node.kind == "tool" then
    local width = 80
    for win in pairs(view.attached_windows) do
      if vim.api.nvim_win_is_valid(win) then
        width = vim.api.nvim_win_get_width(win)
        break
      end
    end
    local mode = view.tool_modes[node.id] or "compact"
    local lines = tool_view.lines(node, mode, width)
    table.insert(lines, "")
    return lines
  end
  if node.kind == "thinking" then
    local label = "Thinking"
    if not disclosure.is_open(view.disclosure, node.id) then
      return { label .. " · <CR> to expand", "" }
    end
    local lines = { label }
    append(lines, text_lines(node.text))
    table.insert(lines, "")
    return lines
  end
  if node.kind == "execution" then
    local label = node.message or node.state or "running"
    if type(node.fraction) == "number" and node.fraction >= 0 and node.fraction <= 1 then
      local length = 16
      local filled = math.floor(node.fraction * length + 0.5)
      local bar = string.rep("━", filled) .. string.rep("─", length - filled)
      label = string.format("%s  %s  %.0f%%", label, bar, node.fraction * 100)
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
  view.name = view.name or buffer_name()
  vim.api.nvim_buf_set_name(view.buffer, view.name)
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

local function last_character_column(line)
  if line == "" then
    return 0
  end
  local characters = vim.str_utfindex(line)
  return vim.str_byteindex(line, math.max(characters - 1, 0))
end

local function tail_visible(win, key)
  local target = M.ensure(key)
  local last = math.max(vim.api.nvim_buf_line_count(target), 1)
  local line = vim.api.nvim_buf_get_lines(target, last - 1, last, false)[1] or ""
  local column = last_character_column(line) + 1
  local ok, position = pcall(vim.fn.screenpos, win, last, column)
  return ok and type(position) == "table" and tonumber(position.row or 0) > 0
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
  state.follow_tail = tail_visible(win, key)
end

local function scroll_to_tail(key)
  local view = store(key)
  local target = M.ensure(key)
  local last = math.max(vim.api.nvim_buf_line_count(target), 1)
  local line = vim.api.nvim_buf_get_lines(target, last - 1, last, false)[1] or ""
  local column = last_character_column(line)
  for win, state in pairs(view.attached_windows) do
    if valid_window(win, key) then
      if state.follow_tail then
        pcall(vim.api.nvim_win_set_cursor, win, { last, column })
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
  vim.wo[win].scrolloff = 0
  if vim.fn.exists("+smoothscroll") == 1 then
    vim.wo[win].smoothscroll = true
  end
  vim.keymap.set("n", "<CR>", function()
    M.toggle_tool(vim.api.nvim_get_current_win())
  end, {
    buffer = M.ensure(resolved),
    silent = true,
    desc = "Cycle Phenix disclosure: compact / human / protocol",
  })
  for key, mode in pairs({ ["1"] = "compact", ["2"] = "human", ["3"] = "protocol" }) do
    vim.keymap.set("n", key, function()
      M.set_tool_mode(vim.api.nvim_get_current_win(), nil, mode)
    end, {
      buffer = M.ensure(resolved),
      silent = true,
      desc = "Phenix tool view: " .. mode,
    })
  end
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

local function node_under_cursor(view, win)
  if not valid_window(win, view.key) then
    return nil
  end
  local row = vim.api.nvim_win_get_cursor(win)[1] - 1
  local target = M.ensure(view.key)
  for node_id, mark_id in pairs(view.marks) do
    local position = vim.api.nvim_buf_get_extmark_by_id(target, namespace, mark_id, { details = true })
    if #position > 0 then
      local start_row = position[1]
      local finish_row = (position[3] and position[3].end_row) or start_row
      if row >= start_row and row <= finish_row then
        return view.last_projection and view.last_projection.nodes[node_id] or nil
      end
    end
  end
  return nil
end

function M.set_tool_mode(win, key, mode)
  win = win or vim.api.nvim_get_current_win()
  key = key or window_keys[win]
  if key == nil then
    return false
  end
  local view = store(key)
  local node = node_under_cursor(view, win)
  if node == nil then
    return false
  end
  if node.kind == "thinking" then
    disclosure.set(view.disclosure, node.id, mode ~= "compact")
  elseif node.kind == "tool" then
    if mode ~= "compact" and mode ~= "human" and mode ~= "protocol" then
      return false
    end
    view.tool_modes[node.id] = mode
  else
    return false
  end
  M.render_node(node, key)
  return true
end

function M.toggle_tool(win, key)
  win = win or vim.api.nvim_get_current_win()
  key = key or window_keys[win]
  if key == nil then
    return false
  end
  local view = store(key)
  local node = node_under_cursor(view, win)
  if node == nil then
    return false
  end
  if node.kind == "thinking" then
    disclosure.toggle(view.disclosure, node.id)
  elseif node.kind == "tool" then
    view.tool_modes[node.id] = tool_view.next_mode(view.tool_modes[node.id] or "compact")
  else
    return false
  end
  M.render_node(node, key)
  return true
end

local function replace(view, start_row, finish_row, lines)
  local target = M.ensure(view.key)
  vim.bo[target].modifiable = true
  vim.api.nvim_buf_set_lines(target, start_row, finish_row, false, lines)
  vim.bo[target].modifiable = false
end

local function define_highlights()
  local normal = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
  local cursorline = vim.api.nvim_get_hl(0, { name = "CursorLine", link = false })
  local bg = cursorline.bg
  if bg == nil or bg == normal.bg then
    local base = normal.bg or 0x1e1e2e
    local function lift(channel)
      return math.min(255, math.floor(channel * 0.88 + 255 * 0.12))
    end
    bg = lift(math.floor(base / 65536)) * 65536
      + lift(math.floor(base / 256) % 256) * 256
      + lift(base % 256)
  end
  vim.api.nvim_set_hl(0, "PhenixUserMessage", { bg = bg })
  local diagnostic = vim.api.nvim_get_hl(0, { name = "DiagnosticInfo", link = false })
  vim.api.nvim_set_hl(0, "PhenixToolLabel", {
    fg = diagnostic.fg or 0x89b4fa,
    bold = true,
  })
  vim.api.nvim_set_hl(0, "PhenixToolCompleted", { link = "DiagnosticOk" })
  vim.api.nvim_set_hl(0, "PhenixToolRunning", { link = "DiagnosticWarn" })
  vim.api.nvim_set_hl(0, "PhenixToolFailed", { link = "DiagnosticError" })
end

define_highlights()
vim.api.nvim_create_autocmd("ColorScheme", { group = group, callback = define_highlights })

local function style_node(view, node, start_row, lines)
  local target = M.ensure(view.key)
  vim.api.nvim_buf_clear_namespace(target, style_namespace, start_row, start_row + math.max(#lines, 1))
  if node.kind == "message" and node.role == "user" then
    for index, line in ipairs(lines) do
      vim.api.nvim_buf_set_extmark(target, style_namespace, start_row + index - 1, 0, {
        end_col = #line,
        hl_group = "PhenixUserMessage",
        hl_eol = true,
        priority = 110,
      })
    end
    return
  end
  if node.kind == "tool" then
    local status, hl_group = tool_view.status(node.state)
    vim.api.nvim_buf_add_highlight(target, style_namespace, "PhenixToolLabel", start_row, 0, 4)
    local header = lines[1] or ""
    local offset = header:find(status, 1, true)
    if offset ~= nil then
      vim.api.nvim_buf_add_highlight(target, style_namespace, hl_group, start_row, offset - 1, offset - 1 + #status)
    end
    return
  end
  local group_name = "Comment"
  if node.kind == "message" then
    group_name = "Special"
  elseif node.kind == "thinking" then
    group_name = "Comment"
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
  local lines = lines_for(view, node)
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
