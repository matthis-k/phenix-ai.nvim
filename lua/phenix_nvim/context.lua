local M = {}

local function uri(buffer)
  local name = vim.api.nvim_buf_get_name(buffer)
  if name == "" then
    return nil
  end
  return vim.uri_from_fname(vim.fn.fnamemodify(name, ":p"))
end

local function reference_uri(value)
  if type(value) ~= "string" then
    return nil, "reference must be text"
  end
  local text = vim.trim(value)
  if text:sub(1, 1) == "@" then
    text = vim.trim(text:sub(2))
  end
  if text == "" then
    return nil, "reference is empty"
  end
  if text:match("^[%a][%w+.-]*://") then
    return text
  end
  return vim.uri_from_fname(vim.fn.fnamemodify(text, ":p"))
end

function M.typed_reference(value)
  local resolved, error = reference_uri(value)
  if resolved == nil then
    return nil, error
  end
  return {
    kind = "resource",
    source = { uri = resolved },
  }
end

function M.pick_reference(callback)
  vim.ui.input({ prompt = "Reference: @", completion = "file" }, function(value)
    if value == nil or value == "" then
      callback(nil, nil)
      return
    end
    local item, error = M.typed_reference(value)
    callback(item, error)
  end)
end

function M.line_selection(start_line, end_line)
  local buffer = vim.api.nvim_get_current_buf()
  start_line = math.max(1, tonumber(start_line) or 1)
  end_line = math.max(start_line, tonumber(end_line) or start_line)
  local lines = vim.api.nvim_buf_get_lines(buffer, start_line - 1, end_line, false)
  local last = lines[#lines] or ""
  return {
    kind = "selection",
    source = {
      uri = uri(buffer),
      start_line = start_line - 1,
      start_column = 0,
      end_line = end_line - 1,
      end_column = #last,
    },
    snapshot = table.concat(lines, "\n"),
  }
end

function M.current_location()
  local buffer = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)
  return {
    kind = "location",
    source = {
      uri = uri(buffer),
      line = cursor[1] - 1,
      column = cursor[2],
    },
  }
end

function M.visual_selection()
  local mode = vim.fn.mode(1)
  if mode == "\22" then
    return nil, "blockwise references are not supported yet"
  end
  if mode ~= "v" and mode ~= "V" then
    return nil, "Reference requires an active visual selection"
  end

  local buffer = vim.api.nvim_get_current_buf()
  local start = vim.fn.getpos("v")
  local finish = vim.fn.getpos(".")
  if start[2] > finish[2] or (start[2] == finish[2] and start[3] > finish[3]) then
    start, finish = finish, start
  end

  local start_row = start[2] - 1
  local end_row = finish[2] - 1
  local start_col = mode == "V" and 0 or start[3] - 1
  local end_col
  local lines
  if mode == "V" then
    lines = vim.api.nvim_buf_get_lines(buffer, start_row, end_row + 1, false)
    end_col = #(lines[#lines] or "")
  else
    end_col = finish[3]
    lines = vim.api.nvim_buf_get_text(buffer, start_row, start_col, end_row, end_col, {})
  end

  return {
    kind = "selection",
    source = {
      uri = uri(buffer),
      start_line = start_row,
      start_column = start_col,
      end_line = end_row,
      end_column = end_col,
    },
    snapshot = table.concat(lines, "\n"),
  }
end

return M
