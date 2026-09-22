local clipboard = require("phenix_nvim.clipboard")
local image = require("phenix_nvim.image")
local model = require("phenix_nvim.compose.model")

local M = {}
local namespace = vim.api.nvim_create_namespace("phenix-compose")
local preview_group = vim.api.nvim_create_augroup("phenix-compose-preview", { clear = true })
local stores = setmetatable({}, { __mode = "k" })
local next_buffer_id = 0

local function valid_window(win)
  return win ~= nil and vim.api.nvim_win_is_valid(win)
end

local function store(document)
  assert(document ~= nil, "Phenix compose document is required")
  local value = stores[document]
  if value == nil then
    value = {
      document = document,
      buffer = nil,
      name = nil,
      markers = {},
      attached_windows = {},
      previews = {},
      recreating = true,
    }
    stores[document] = value
  end
  return value
end

local function close_preview(view, win, id)
  local window_previews = view.previews[win]
  local preview = window_previews and window_previews[id] or nil
  if preview ~= nil then
    image.close(preview)
    window_previews[id] = nil
  end
  if window_previews ~= nil and next(window_previews) == nil then
    view.previews[win] = nil
  end
end

local function close_item_previews(view, id)
  for win in pairs(view.previews) do
    close_preview(view, win, id)
  end
end

local function close_window_previews(view, win)
  local window_previews = view.previews[win]
  if window_previews == nil then
    return
  end
  for id in pairs(window_previews) do
    close_preview(view, win, id)
  end
  view.previews[win] = nil
end

local function close_previews(view)
  for win in pairs(view.previews) do
    close_window_previews(view, win)
  end
end

local function marker_position(view, item)
  local target = view.buffer
  local extmark = view.markers[item.id]
  if target == nil or extmark == nil or not vim.api.nvim_buf_is_valid(target) then
    return nil
  end
  local position = vim.api.nvim_buf_get_extmark_by_id(target, namespace, extmark, {})
  if type(position) ~= "table" or #position < 2 then
    return nil
  end
  local row, column = position[1], position[2]
  local marker = M.marker(item)
  local ok, text = pcall(vim.api.nvim_buf_get_text, target, row, column, row, column + #marker, {})
  if not ok or table.concat(text, "\n") ~= marker then
    return nil
  end
  return row, column
end

local function placement(win, row, column)
  local position = vim.fn.screenpos(win, row + 1, column + 1)
  if type(position) ~= "table" or position.row == nil or position.col == nil then
    return nil
  end
  if position.row <= 0 or position.col <= 0 then
    return nil
  end
  return {
    row = position.row,
    col = position.col,
  }
end

function M.reconcile_markers(document)
  local view = store(document)
  local target = view.buffer
  if target == nil or not vim.api.nvim_buf_is_valid(target) then
    return
  end
  local active = {}
  local stale = {}
  for id in pairs(view.markers) do
    local item = model.get(document, id)
    if item ~= nil and marker_position(view, item) ~= nil then
      active[id] = true
    else
      table.insert(stale, id)
    end
  end
  for _, id in ipairs(stale) do
    local extmark = view.markers[id]
    if extmark ~= nil then
      pcall(vim.api.nvim_buf_del_extmark, target, namespace, extmark)
    end
    view.markers[id] = nil
    close_item_previews(view, id)
  end
  model.reconcile(document, active)
end

local function refresh_window(document, view, win)
  local target = view.buffer
  if target == nil or not vim.api.nvim_buf_is_valid(target) then
    close_window_previews(view, win)
    view.attached_windows[win] = nil
    return
  end
  if not valid_window(win) or vim.api.nvim_win_get_buf(win) ~= target then
    close_window_previews(view, win)
    view.attached_windows[win] = nil
    return
  end

  local window_previews = view.previews[win] or {}
  view.previews[win] = window_previews
  for id in pairs(window_previews) do
    local item = model.get(document, id)
    if item == nil or item.kind ~= "image" or view.markers[id] == nil then
      close_preview(view, win, id)
    end
  end

  for id in pairs(view.markers) do
    local item = model.get(document, id)
    if item == nil or item.kind ~= "image" then
      close_preview(view, win, id)
    else
      local row, column = marker_position(view, item)
      local where = row ~= nil and placement(win, row, column) or nil
      if where == nil then
        close_preview(view, win, id)
      elseif window_previews[id] ~= nil then
        if not image.update(window_previews[id], where) then
          close_preview(view, win, id)
          window_previews = view.previews[win] or {}
          view.previews[win] = window_previews
          window_previews[id] = image.preview(item, where)
        end
      else
        window_previews[id] = image.preview(item, where)
      end
    end
  end
end

function M.refresh_previews(document, win)
  if document ~= nil then
    local view = store(document)
    if win ~= nil then
      refresh_window(document, view, win)
      return
    end
    for attached in pairs(view.attached_windows) do
      refresh_window(document, view, attached)
    end
    return
  end
  for current_document, view in pairs(stores) do
    for attached in pairs(view.attached_windows) do
      refresh_window(current_document, view, attached)
    end
  end
end

local function native_paste(key)
  local count = vim.v.count > 0 and tostring(vim.v.count) or ""
  local register = vim.v.register
  local register_prefix = register ~= nil and register ~= '"' and ('"' .. register) or ""
  vim.cmd.normal({ bang = true, args = { count .. register_prefix .. key } })
end

local function paste(document, key)
  if clipboard.register_uses_system_clipboard(vim.v.register) then
    local attached = require("phenix_nvim.actions").attach_image("clipboard", { quiet = true, document = document })
    if attached ~= nil then
      return
    end
  end
  native_paste(key)
end

local function buffer_name()
  next_buffer_id = next_buffer_id + 1
  if next_buffer_id == 1 then
    return "phenix://compose"
  end
  return "phenix://compose/" .. tostring(next_buffer_id)
end

function M.ensure(document)
  local view = store(document)
  if view.buffer ~= nil and vim.api.nvim_buf_is_valid(view.buffer) then
    return view.buffer
  end

  local target = vim.api.nvim_create_buf(false, true)
  view.buffer = target
  view.markers = {}
  view.attached_windows = {}
  view.previews = {}
  vim.bo[target].buflisted = false
  vim.bo[target].buftype = "acwrite"
  vim.bo[target].bufhidden = "hide"
  vim.bo[target].swapfile = false
  vim.bo[target].filetype = "markdown"
  vim.b[target].phenix_internal = true
  vim.b[target].phenix_role = "compose"
  view.name = view.name or buffer_name()
  vim.api.nvim_buf_set_name(target, view.name)

  vim.keymap.set("n", "<CR>", function()
    require("phenix_nvim.actions").send({ document = document })
  end, {
    buffer = target,
    desc = "Send Phenix prompt",
    silent = true,
  })
  vim.keymap.set("n", "p", function()
    paste(document, "p")
  end, {
    buffer = target,
    desc = "Paste text or clipboard image",
    silent = true,
  })
  vim.keymap.set("n", "P", function()
    paste(document, "P")
  end, {
    buffer = target,
    desc = "Paste text or clipboard image before cursor",
    silent = true,
  })
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = target,
    callback = function()
      require("phenix_nvim.actions").send({ document = document })
    end,
  })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    buffer = target,
    callback = function()
      if view.buffer ~= target then
        return
      end
      model.touch(document)
      M.reconcile_markers(document)
      M.refresh_previews(document)
      if vim.api.nvim_buf_is_valid(target) then
        vim.bo[target].modified = false
      end
    end,
  })
  vim.api.nvim_create_autocmd("QuitPre", {
    buffer = target,
    callback = function()
      if vim.api.nvim_buf_is_valid(target) then
        vim.bo[target].modified = false
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = target,
    callback = function()
      if view.buffer ~= target then
        return
      end
      close_previews(view)
      view.markers = {}
      view.attached_windows = {}
      model.clear(document)
      view.buffer = nil
      if view.recreating then
        vim.schedule(function()
          if view.buffer == nil and view.recreating then
            M.ensure(document)
          end
        end)
      end
    end,
  })
  return target
end

function M.attach_window(document, win)
  local view = store(document)
  local target = M.ensure(document)
  if not valid_window(win) or vim.api.nvim_win_get_buf(win) ~= target then
    return
  end
  view.attached_windows[win] = true
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].breakindent = true
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].foldcolumn = "0"
  vim.wo[win].winfixheight = true
  M.refresh_previews(document, win)
end

function M.detach_window(win)
  if win == nil then
    for _, view in pairs(stores) do
      for attached in pairs(view.attached_windows) do
        close_window_previews(view, attached)
      end
      view.attached_windows = {}
    end
    return
  end
  for _, view in pairs(stores) do
    if view.attached_windows[win] ~= nil then
      close_window_previews(view, win)
      view.attached_windows[win] = nil
      return
    end
  end
end

function M.document_for_buffer(target)
  for document, view in pairs(stores) do
    if view.buffer == target then
      return document
    end
  end
  return nil
end

function M.marker(item)
  return "⟦phenix:" .. item.id .. "⟧"
end

local function label(item)
  if item.kind == "selection" and item.source then
    return string.format(" %s:%d-%d", item.kind, item.source.start_line + 1, item.source.end_line + 1)
  end
  if item.kind == "image" then
    return " image · " .. tostring(item.name or item.mime_type or "attachment")
  end
  return " " .. item.kind
end

function M.insert(document, item, win)
  local view = store(document)
  local target = M.ensure(document)
  if not valid_window(win) or vim.api.nvim_win_get_buf(win) ~= target then
    for attached in pairs(view.attached_windows) do
      if valid_window(attached) and vim.api.nvim_win_get_buf(attached) == target then
        win = attached
        break
      end
    end
  end
  if not valid_window(win) then
    return nil, "compose buffer is not visible"
  end
  local cursor = vim.api.nvim_win_get_cursor(win)
  local row = cursor[1] - 1
  local column = cursor[2]
  local marker = M.marker(item)
  vim.api.nvim_buf_set_text(target, row, column, row, column, { marker })
  view.markers[item.id] = vim.api.nvim_buf_set_extmark(target, namespace, row, column, {
    end_row = row,
    end_col = column + #marker,
    hl_group = "Special",
    virt_text = { { label(item), "Comment" } },
    right_gravity = false,
  })
  model.touch(document)
  vim.api.nvim_win_set_cursor(win, { row + 1, column + #marker })
  M.refresh_previews(document, win)
  return true
end

function M.serialize_text(text, document)
  local result = {}
  local active = {}
  local cursor = 1
  while true do
    local first, last, id = text:find("⟦phenix:([%w_%-]+)⟧", cursor)
    if first == nil then
      break
    end
    if first > cursor then
      table.insert(result, { kind = "text", text = text:sub(cursor, first - 1) })
    end
    local item = model.get(document, id)
    if item == nil then
      return nil, "compose marker references missing item " .. id
    end
    active[id] = true
    table.insert(result, vim.deepcopy(item))
    cursor = last + 1
  end
  if cursor <= #text then
    table.insert(result, { kind = "text", text = text:sub(cursor) })
  end
  model.reconcile(document, active)
  return result
end

local function append_text(result, lines)
  local text = table.concat(lines, "\n")
  if text ~= "" then
    table.insert(result, { kind = "text", text = text })
  end
end

function M.serialize(document)
  local view = store(document)
  local target = M.ensure(document)
  M.reconcile_markers(document)

  local attachments = {}
  local active = {}
  for id in pairs(view.markers) do
    local item = model.get(document, id)
    if item ~= nil then
      local row, column = marker_position(view, item)
      if row ~= nil then
        table.insert(attachments, {
          id = id,
          item = item,
          row = row,
          column = column,
          end_column = column + #M.marker(item),
        })
      end
    end
  end
  table.sort(attachments, function(left, right)
    if left.row == right.row then
      return left.column < right.column
    end
    return left.row < right.row
  end)

  local result = {}
  local row, column = 0, 0
  for _, attachment in ipairs(attachments) do
    append_text(result, vim.api.nvim_buf_get_text(
      target,
      row,
      column,
      attachment.row,
      attachment.column,
      {}
    ))
    table.insert(result, vim.deepcopy(attachment.item))
    active[attachment.id] = true
    row = attachment.row
    column = attachment.end_column
  end

  local line_count = vim.api.nvim_buf_line_count(target)
  local last_row = math.max(line_count - 1, 0)
  local last_line = vim.api.nvim_buf_get_lines(target, last_row, last_row + 1, false)[1] or ""
  append_text(result, vim.api.nvim_buf_get_text(target, row, column, last_row, #last_line, {}))

  model.reconcile(document, active)
  M.refresh_previews(document)
  return result
end

function M.clear(document)
  local view = store(document)
  local target = M.ensure(document)
  close_previews(view)
  view.markers = {}
  vim.api.nvim_buf_clear_namespace(target, namespace, 0, -1)
  vim.api.nvim_buf_set_lines(target, 0, -1, false, { "" })
  model.clear(document)
  vim.bo[target].modified = false
end

vim.api.nvim_create_autocmd({ "WinScrolled", "WinResized", "VimResized" }, {
  group = preview_group,
  callback = function()
    vim.schedule(function()
      M.refresh_previews()
    end)
  end,
})

vim.api.nvim_create_autocmd("WinClosed", {
  group = preview_group,
  callback = function(args)
    local win = tonumber(args.match)
    if win ~= nil then
      M.detach_window(win)
    end
  end,
})

return M
