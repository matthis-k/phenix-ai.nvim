-- Editable, revisioned queue entries. Windows use only Neovim character cells.
local M = {}
local views = setmetatable({}, { __mode = "k" })
local next_id = 0
local ROWS = 3
local MIN_TRANSCRIPT = 3
local group = vim.api.nvim_create_augroup("phenix-follow-up-queue", { clear = true })

local function valid(win)
  return win ~= nil and vim.api.nvim_win_is_valid(win)
end

local function view_for(surface)
  local view = views[surface]
  if view == nil then
    view = { entries = {}, by_item = {} }
    views[surface] = view
  end
  return view
end

local function content_text(content)
  local result = {}
  for _, part in ipairs(content or {}) do
    if part.kind == "text" then
      result[#result + 1] = part.text or ""
    end
  end
  return table.concat(result)
end

local function replace_text(content, text)
  local result, found = {}, false
  for _, part in ipairs(content or {}) do
    if part.kind == "text" then
      if not found then
        result[#result + 1] = { kind = "text", text = text }
        found = true
      end
    else
      result[#result + 1] = vim.deepcopy(part)
    end
  end
  if not found then
    table.insert(result, 1, { kind = "text", text = text })
  end
  return result
end

local function attachment_count(content)
  local count = 0
  for _, part in ipairs(content or {}) do
    if part.kind ~= "text" then
      count = count + 1
    end
  end
  return count
end

local function is_focused(entry)
  return valid(entry.win) and vim.api.nvim_get_current_win() == entry.win
end

function M.can_dispatch(surface, item)
  local view = views[surface]
  local entry = view and view.by_item[item] or nil
  if item.ready == false or item.pending ~= nil then
    return false
  end
  return entry == nil or (not entry.dirty and (not is_focused(entry) or entry.released))
end

local function title(index, total, item, entry)
  local status = entry.dirty and "modified · :w to release"
    or (is_focused(entry) and not entry.released and "editing · :w to release")
    or (item.ready == false and "held")
    or "ready"
  local count = attachment_count(item.content)
  return string.format("Follow-up %d/%d · %s%s", index, total, status,
    count > 0 and (" · " .. count .. " attachment(s)") or "")
end

local function close_entry(entry)
  if valid(entry.win) then
    require("phenix_nvim.sidebar").detach_queue_window(entry.win)
    pcall(vim.api.nvim_win_close, entry.win, true)
  end
  entry.win = nil
  if entry.buf and vim.api.nvim_buf_is_valid(entry.buf) then
    pcall(vim.api.nvim_buf_delete, entry.buf, { force = true })
  end
end

local function ensure_entry(surface, view, item)
  local entry = view.by_item[item]
  if entry and vim.api.nvim_buf_is_valid(entry.buf) then
    return entry
  end
  next_id = next_id + 1
  entry = { buf = vim.api.nvim_create_buf(false, true), dirty = false, released = false }
  view.by_item[item] = entry
  vim.bo[entry.buf].buftype = "acwrite"
  vim.bo[entry.buf].bufhidden = "hide"
  vim.bo[entry.buf].buflisted = false
  vim.bo[entry.buf].swapfile = false
  vim.bo[entry.buf].filetype = "markdown"
  vim.b[entry.buf].phenix_internal = true
  vim.b[entry.buf].phenix_role = "followup"
  vim.api.nvim_buf_set_name(entry.buf, "phenix://followup/" .. next_id)
  local source = content_text(item.content)
  vim.api.nvim_buf_set_lines(entry.buf, 0, -1, false,
    source ~= "" and vim.split(source, "\n", { plain = true }) or { "" })
  vim.bo[entry.buf].modified = false
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    buffer = entry.buf,
    callback = function()
      if view.by_item[item] ~= entry then
        return
      end
      entry.dirty = true
      entry.released = false
      item.ready = false
      M.relayout(surface)
    end,
  })
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = entry.buf,
    callback = function()
      if view.by_item[item] ~= entry then
        return
      end
      item.content = replace_text(item.content,
        table.concat(vim.api.nvim_buf_get_lines(entry.buf, 0, -1, false), "\n"))
      item.revision = (item.revision or 0) + 1
      item.ready = true
      entry.dirty = false
      entry.released = true
      vim.bo[entry.buf].modified = false
      M.relayout(surface)
      if view.on_ready then vim.schedule(view.on_ready) end
    end,
  })
  vim.keymap.set("n", "<C-x>", function()
    for index, queued in ipairs(view.entries) do
      if queued == item and view.on_remove then
        view.on_remove(index)
        return
      end
    end
  end, { buffer = entry.buf, silent = true, desc = "Remove queued follow-up" })
  vim.keymap.set("n", "r", function()
    if view.on_retry then view.on_retry() end
  end, { buffer = entry.buf, silent = true, desc = "Resume paused queue" })
  return entry
end

function M.reserved_rows(surface, host_height, compose_height)
  local view = views[surface]
  if view == nil then return 0 end
  local available = math.max(0, host_height - compose_height - MIN_TRANSCRIPT)
  return math.min(#view.entries, math.floor(available / ROWS)) * ROWS
end

function M.relayout(surface)
  local view = views[surface]
  if view == nil or not valid(surface.host_win) or not valid(surface.compose_win) then
    return
  end
  local height = vim.api.nvim_win_get_height(surface.host_win)
  local compose_height = vim.api.nvim_win_get_height(surface.compose_win)
  local count = M.reserved_rows(surface, height, compose_height) / ROWS
  local width = vim.api.nvim_win_get_width(surface.host_win)
  local top = height - compose_height - count * ROWS
  for index, item in ipairs(view.entries) do
    local entry = ensure_entry(surface, view, item)
    if index <= count then
      local config = {
        relative = "win", win = surface.host_win, anchor = "NW",
        row = top + (index - 1) * ROWS, col = 0,
        width = width, height = ROWS, style = "minimal",
        border = "none", focusable = true, zindex = 62,
      }
      if valid(entry.win) then
        pcall(vim.api.nvim_win_set_config, entry.win, config)
      else
        entry.win = vim.api.nvim_open_win(entry.buf, false, config)
        require("phenix_nvim.sidebar").attach_queue_window(surface, entry.win)
        vim.wo[entry.win].wrap = true
        vim.wo[entry.win].number = false
        vim.wo[entry.win].relativenumber = false
        vim.wo[entry.win].signcolumn = "no"
      end
      vim.wo[entry.win].winbar = title(index, #view.entries, item, entry)
    elseif valid(entry.win) then
      require("phenix_nvim.sidebar").detach_queue_window(entry.win)
      pcall(vim.api.nvim_win_close, entry.win, true)
      entry.win = nil
    end
  end
end

function M.render(surface, items, on_remove, on_retry, on_ready)
  local view = view_for(surface)
  view.entries, view.on_remove, view.on_retry, view.on_ready =
    items, on_remove, on_retry, on_ready
  local seen = {}
  for _, item in ipairs(items) do seen[item] = true end
  for item, entry in pairs(view.by_item) do
    if not seen[item] then
      view.by_item[item] = nil
      close_entry(entry)
    end
  end
  -- Always create buffers, including while the chat is hidden.
  for _, item in ipairs(items) do ensure_entry(surface, view, item) end
  require("phenix_nvim.sidebar").reconcile()
  M.relayout(surface)
end

function M.on_focus(win)
  for surface, view in pairs(views) do
    for index, item in ipairs(view.entries) do
      local entry = view.by_item[item]
      if entry and entry.win == win then
        entry.released = false
        vim.wo[win].winbar = title(index, #view.entries, item, entry)
        return
      end
    end
  end
end

function M.on_leave(win)
  for surface, view in pairs(views) do
    for _, item in ipairs(view.entries) do
      local entry = view.by_item[item]
      if entry and entry.win == win then
        if view.on_ready then vim.schedule(view.on_ready) end
        return
      end
    end
  end
end

function M.close(surface)
  local view = views[surface]
  if view == nil then return end
  views[surface] = nil
  for _, entry in pairs(view.by_item) do close_entry(entry) end
end

vim.api.nvim_create_autocmd("WinEnter", {
  group = group, callback = function() M.on_focus(vim.api.nvim_get_current_win()) end,
})
vim.api.nvim_create_autocmd("WinLeave", {
  group = group, callback = function() M.on_leave(vim.api.nvim_get_current_win()) end,
})

return M
