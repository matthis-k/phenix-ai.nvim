local M = {}
local views = setmetatable({}, { __mode = "k" })

local function valid(win)
  return win ~= nil and vim.api.nvim_win_is_valid(win)
end

local function summarize(segments)
  local parts = {}
  local attachments = 0
  for _, segment in ipairs(segments or {}) do
    if segment.kind == "text" then
      table.insert(parts, segment.text or "")
    else
      attachments = attachments + 1
    end
  end
  local text = vim.trim(table.concat(parts):gsub("%s+", " "))
  if attachments > 0 then
    text = text .. (text ~= "" and " " or "") .. "[" .. attachments .. " attachment(s)]"
  end
  if text == "" then
    text = "(empty)"
  end
  if vim.fn.strdisplaywidth(text) > 100 then
    text = vim.fn.strcharpart(text, 0, 96) .. "…"
  end
  return text
end

local function close(view)
  if view == nil then
    return
  end
  if valid(view.window) then
    pcall(vim.api.nvim_win_close, view.window, true)
  end
  view.window = nil
  if view.buffer ~= nil and vim.api.nvim_buf_is_valid(view.buffer) then
    pcall(vim.api.nvim_buf_delete, view.buffer, { force = true })
  end
  view.buffer = nil
end

function M.render(surface, items, on_remove)
  local view = views[surface]
  if view == nil then
    view = {}
    views[surface] = view
  end
  if #items == 0 then
    close(view)
    return
  end
  if not valid(surface.compose_win) then
    return
  end

  local lines = { "Queued follow-ups  " .. tostring(#items) }
  for index, item in ipairs(items) do
    table.insert(lines, tostring(index) .. ". " .. summarize(item.content))
  end
  local max_width = math.max(24, vim.api.nvim_win_get_width(surface.compose_win))
  local width = math.max(24, math.min(max_width, 72))
  local height = math.min(#lines, 9)
  local row = -height - 1

  if view.buffer == nil or not vim.api.nvim_buf_is_valid(view.buffer) then
    view.buffer = vim.api.nvim_create_buf(false, true)
    vim.bo[view.buffer].buftype = "nofile"
    vim.bo[view.buffer].bufhidden = "wipe"
    vim.bo[view.buffer].swapfile = false
    vim.bo[view.buffer].modifiable = false
    vim.keymap.set("n", "dd", function()
      local index = vim.api.nvim_win_get_cursor(0)[1] - 1
      if index > 0 and index <= #items and on_remove ~= nil then
        on_remove(index)
      end
    end, { buffer = view.buffer, silent = true, desc = "Remove queued follow-up" })
  end
  vim.bo[view.buffer].modifiable = true
  vim.api.nvim_buf_set_lines(view.buffer, 0, -1, false, lines)
  vim.bo[view.buffer].modifiable = false

  if valid(view.window) then
    vim.api.nvim_win_set_config(view.window, {
      relative = "win",
      win = surface.compose_win,
      row = row,
      col = 0,
      width = width,
      height = height,
    })
  else
    view.window = vim.api.nvim_open_win(view.buffer, false, {
      relative = "win",
      win = surface.compose_win,
      row = row,
      col = 0,
      width = width,
      height = height,
      focusable = true,
      style = "minimal",
      border = "rounded",
      zindex = 60,
    })
    vim.wo[view.window].wrap = false
    vim.wo[view.window].cursorline = true
  end
end

function M.close(surface)
  close(views[surface])
  views[surface] = nil
end

return M
