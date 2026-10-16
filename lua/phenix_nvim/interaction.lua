local M = {}

local function notify_error(message)
  if vim.notify ~= nil then
    vim.notify(message, vim.log.levels.ERROR, { title = "Phenix" })
  end
end

local function finish_once(callback)
  local settled = false
  return function(...)
    if settled then
      return
    end
    settled = true
    callback(...)
  end
end

local function fallback_select(items, options, callback)
  local done = finish_once(callback)
  local prompt = options.prompt or "Select"
  local lines = { prompt }
  local width = #prompt
  for index, item in ipairs(items) do
    local line = string.format("%d. %s", index, tostring(item))
    table.insert(lines, line)
    width = math.max(width, #line)
  end
  width = math.max(20, math.min(width + 2, math.max(20, vim.o.columns - 4)))
  local height = #lines
  local row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1)
  local col = math.max(0, math.floor((vim.o.columns - width) / 2))
  local buffer = vim.api.nvim_create_buf(false, true)
  vim.bo[buffer].buftype = "nofile"
  vim.bo[buffer].bufhidden = "wipe"
  vim.bo[buffer].swapfile = false
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, lines)
  vim.bo[buffer].modifiable = false
  local win = vim.api.nvim_open_win(buffer, true, {
    relative = "editor",
    style = "minimal",
    border = "rounded",
    width = width,
    height = height,
    row = row,
    col = col,
  })
  if #items > 0 then
    vim.api.nvim_win_set_cursor(win, { 2, 0 })
  end

  local function choose(index)
    local choice = items[index]
    done(choice, choice ~= nil and index or nil)
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end

  vim.keymap.set("n", "<CR>", function()
    choose(vim.api.nvim_win_get_cursor(win)[1] - 1)
  end, { buffer = buffer, nowait = true, silent = true })
  vim.keymap.set("n", "<Esc>", function()
    choose(0)
  end, { buffer = buffer, nowait = true, silent = true })
  vim.keymap.set("n", "q", function()
    choose(0)
  end, { buffer = buffer, nowait = true, silent = true })
  for index = 1, math.min(#items, 9) do
    vim.keymap.set("n", tostring(index), function()
      choose(index)
    end, { buffer = buffer, nowait = true, silent = true })
  end
  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(win),
    once = true,
    callback = function()
      done(nil, nil)
    end,
  })
end

local function select(items, options, callback)
  if vim.ui ~= nil and type(vim.ui.select) == "function" then
    vim.ui.select(items, options, callback)
  else
    fallback_select(items, options, callback)
  end
end

local function input(options, callback)
  if vim.ui ~= nil and type(vim.ui.input) == "function" then
    vim.ui.input(options, callback)
    return
  end
  vim.schedule(function()
    local ok, value = pcall(vim.fn.input, options.prompt or "")
    callback(ok and value or nil)
  end)
end

local function parse_integer(text, signed)
  local value = tonumber(text)
  if value == nil or value ~= math.floor(value) then
    return nil, signed and "expected integer" or "expected unsigned integer"
  end
  if not signed and value < 0 then
    return nil, "expected unsigned integer"
  end
  return value
end

local function parse_scalar(form, text)
  if form.kind == "string" then
    return text
  end
  if form.kind == "integer" then
    return parse_integer(text, form.signed == true)
  end
  if form.kind == "number" then
    local value = tonumber(text)
    if value == nil or value ~= value or value == math.huge or value == -math.huge then
      return nil, "expected finite number"
    end
    return value
  end
  if form.kind == "boolean" then
    if text == "true" then
      return true
    end
    if text == "false" then
      return false
    end
    return nil, "expected true or false"
  end
  return nil, "unsupported scalar input"
end

local function split_list(text)
  local result = {}
  if text:match("^%s*$") then
    return result
  end
  for item in text:gmatch("[^,]+") do
    table.insert(result, vim.trim(item))
  end
  return result
end

local ask

local function ask_scalar(form, label, callback)
  if form.optional then
    if form.kind == "boolean" then
      select({ "None", "True", "False" }, { prompt = label }, function(choice)
        if choice == nil then
          callback(nil, true)
        elseif choice == "None" then
          callback(nil, false)
        else
          callback(choice == "True", false)
        end
      end)
      return
    end
    input({ prompt = label .. " (blank = none): " }, function(text)
      if text == nil then
        callback(nil, true)
        return
      end
      if text == "" then
        callback(nil, false)
        return
      end
      local value, error = parse_scalar(form, text)
      if error ~= nil then
        notify_error(label .. ": " .. error)
        ask_scalar(form, label, callback)
      else
        callback(value, false)
      end
    end)
    return
  end

  if form.kind == "boolean" then
    select({ "True", "False" }, { prompt = label }, function(choice)
      if choice == nil then
        callback(nil, true)
      else
        callback(choice == "True", false)
      end
    end)
    return
  end

  input({ prompt = label .. ": " }, function(text)
    if text == nil then
      callback(nil, true)
      return
    end
    local value, error = parse_scalar(form, text)
    if error ~= nil then
      notify_error(label .. ": " .. error)
      ask_scalar(form, label, callback)
    else
      callback(value, false)
    end
  end)
end

local function ask_object(form, label, callback)
  local fields = form.fields or {}
  local result = {}
  local index = 1
  local function next_field()
    local field = fields[index]
    if field == nil then
      callback(result, false)
      return
    end
    local field_label = label == "" and field.name or (label .. "." .. field.name)
    ask(field.schema, field_label, function(value, cancelled, error)
      if cancelled or error ~= nil then
        callback(nil, cancelled, error)
        return
      end
      if value ~= nil then
        result[field.name] = value
      end
      index = index + 1
      next_field()
    end)
  end
  next_field()
end

local function ask_enum(form, label, callback)
  select(form.options or {}, { prompt = label }, function(choice)
    if choice == nil then
      callback(nil, true)
    else
      callback({ kind = choice }, false)
    end
  end)
end

local function ask_list(form, label, callback)
  local item = form.item or {}
  input({ prompt = label .. " (comma-separated): " }, function(text)
    if text == nil then
      callback(nil, true)
      return
    end
    local values = {}
    for _, token in ipairs(split_list(text)) do
      if item.kind == "enum" then
        if not vim.tbl_contains(item.options or {}, token) then
          notify_error(label .. ": unknown value " .. token)
          ask_list(form, label, callback)
          return
        end
        table.insert(values, { kind = token })
      else
        local value, error = parse_scalar(item, token)
        if error ~= nil then
          notify_error(label .. ": " .. error)
          ask_list(form, label, callback)
          return
        end
        table.insert(values, value)
      end
    end
    callback(values, false)
  end)
end

ask = function(form, label, callback)
  if type(form) ~= "table" or type(form.kind) ~= "string" then
    callback(nil, false, "invalid interaction form")
    return
  end
  if form.kind == "string" or form.kind == "boolean" or form.kind == "integer" or form.kind == "number" then
    ask_scalar(form, label, callback)
  elseif form.kind == "object" then
    ask_object(form, label, callback)
  elseif form.kind == "enum" then
    ask_enum(form, label, callback)
  elseif form.kind == "list" then
    ask_list(form, label, callback)
  else
    callback(nil, false, "unsupported interaction form " .. tostring(form.kind))
  end
end

-- Render exactly the choices supplied by Phenix's ACP permission request.
-- A missing or dismissed dialog returns cancellation, not authorization.
function M.acp_permission(event, callback)
  assert(type(event) == "table" and type(callback) == "function")
  local options = event.options or {}
  if #options == 0 then callback(nil); return end
  local title = (event.tool_call and event.tool_call.title) or "Requested operation"
  select(options, {
    prompt = "Phenix permission · " .. tostring(title),
    format_item = function(item) return item.name or item.optionId end,
  }, function(selected)
    callback(selected and selected.optionId or nil)
  end)
end

function M.permission(request, reply)
  select({ "Allow once", "Deny" }, {
    prompt = "Phenix permission · " .. (request.description or "Allow this action?"),
  }, function(choice)
    if choice == "Allow once" then
      reply:allow_once()
    elseif choice == "Deny" then
      reply:deny()
    else
      reply:cancel()
    end
  end)
end

function M.elicitation(request, reply)
  ask(request.form, request.message or "Phenix input", function(value, cancelled, error)
    if error ~= nil then
      notify_error(error)
      reply:cancel()
    elseif cancelled then
      reply:cancel()
    else
      local ok, accept_error = pcall(reply.accept, reply, value)
      if not ok then
        notify_error(accept_error)
      end
    end
  end)
end

return M
