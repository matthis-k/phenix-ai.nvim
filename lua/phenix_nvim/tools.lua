local context = require("phenix_nvim.context")

local M = {}

local templates = {}
local revision = 0
local default_stops = {}

local unit = { type = "unit" }
local bool = { type = "bool" }
local u64 = { type = "u64" }
local string_type = { type = "string" }

local function option(item)
  return { type = "option", value = item }
end

local function list(item)
  return { type = "list", value = item }
end

local function record(fields)
  return { type = "table", value = fields }
end

local position = record({
  line = u64,
  column = u64,
})

local range = record({
  start = position,
  ["end"] = position,
})

local location = record({
  uri = string_type,
  range = option(range),
})

local selection_snapshot = record({
  location = location,
  text = string_type,
})

local buffer_info = record({
  uri = string_type,
  filetype = string_type,
  modified = bool,
})

local buffer_snapshot = record({
  info = buffer_info,
  changedtick = u64,
  text = string_type,
  truncated = bool,
})

local diagnostic = record({
  location = location,
  severity = string_type,
  message = string_type,
  source = option(string_type),
  code = option(string_type),
})

local quickfix_item = record({
  location = location,
  text = string_type,
  type = option(string_type),
})

local viewport = record({
  location = location,
  text = string_type,
  truncated = bool,
})

local function bounded_integer(value, default, maximum, name)
  if value == nil then
    return default
  end
  if type(value) ~= "number" or value ~= math.floor(value) or value < 0 then
    error(name .. " must be a non-negative integer")
  end
  return math.min(value, maximum)
end

local function utf8_prefix(text, max_bytes)
  if #text <= max_bytes then
    return text, false
  end
  local cut = max_bytes
  while cut > 0 do
    local next_byte = string.byte(text, cut + 1)
    if next_byte == nil or next_byte < 0x80 or next_byte >= 0xC0 then
      break
    end
    cut = cut - 1
  end
  return string.sub(text, 1, cut), true
end

local function buffer_uri(buffer)
  return context.buffer_uri(buffer)
end

local function buffer_info_for(buffer)
  return {
    uri = buffer_uri(buffer),
    filetype = vim.bo[buffer].filetype or "",
    modified = vim.bo[buffer].modified == true,
  }
end

local function buffer_for_uri(uri)
  if uri == nil then
    return vim.api.nvim_get_current_buf()
  end
  for _, buffer in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buffer)
      and vim.api.nvim_buf_is_loaded(buffer)
      and buffer_uri(buffer) == uri
    then
      return buffer
    end
  end
  error("unknown loaded buffer URI " .. tostring(uri))
end

local function buffer_text(buffer)
  return table.concat(vim.api.nvim_buf_get_lines(buffer, 0, -1, false), "\n")
end

local function severity_name(value)
  local severity = vim.diagnostic.severity
  if value == severity.ERROR then
    return "error"
  elseif value == severity.WARN then
    return "warn"
  elseif value == severity.INFO then
    return "info"
  elseif value == severity.HINT then
    return "hint"
  end
  return "unknown"
end

local function diagnostic_location(buffer, item)
  local start_line = math.max(0, item.lnum or 0)
  local start_column = math.max(0, item.col or 0)
  local end_line = math.max(start_line, item.end_lnum or start_line)
  local end_column = math.max(0, item.end_col or start_column)
  return {
    uri = buffer_uri(buffer),
    range = {
      start = { line = start_line, column = start_column },
      ["end"] = { line = end_line, column = end_column },
    },
  }
end

local function quickfix_location(item)
  local buffer = tonumber(item.bufnr) or 0
  local uri
  if buffer > 0 and vim.api.nvim_buf_is_valid(buffer) then
    uri = buffer_uri(buffer)
  elseif type(item.filename) == "string" and item.filename ~= "" then
    uri = vim.uri_from_fname(vim.fn.fnamemodify(item.filename, ":p"))
  else
    return nil
  end
  local start_line = math.max(0, (tonumber(item.lnum) or 1) - 1)
  local start_column = math.max(0, (tonumber(item.col) or 1) - 1)
  local end_line = math.max(start_line, (tonumber(item.end_lnum) or (start_line + 1)) - 1)
  local end_column = math.max(start_column, (tonumber(item.end_col) or (start_column + 1)) - 1)
  return {
    uri = uri,
    range = {
      start = { line = start_line, column = start_column },
      ["end"] = { line = end_line, column = end_column },
    },
  }
end

local function current_location_tool()
  local snapshot = context.snapshot()
  return {
    uri = snapshot.uri,
    range = nil,
  }
end

local function selection_tool()
  return context.snapshot().selection
end

local function buffer_tool(input)
  input = input or {}
  local max_bytes = bounded_integer(input.max_bytes, 65536, 262144, "max_bytes")
  local buffer = buffer_for_uri(input.uri)
  local text, truncated = utf8_prefix(buffer_text(buffer), max_bytes)
  return {
    info = buffer_info_for(buffer),
    changedtick = vim.api.nvim_buf_get_changedtick(buffer),
    text = text,
    truncated = truncated,
  }
end

local function buffers_tool()
  local result = {}
  for _, buffer in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buffer) and vim.api.nvim_buf_is_loaded(buffer) then
      table.insert(result, buffer_info_for(buffer))
    end
  end
  table.sort(result, function(left, right)
    return left.uri < right.uri
  end)
  return result
end

local function diagnostics_tool(input)
  input = input or {}
  local limit = bounded_integer(input.limit, 100, 500, "limit")
  local buffer = buffer_for_uri(input.uri)
  local values = vim.diagnostic.get(buffer)
  table.sort(values, function(left, right)
    local left_key = {
      left.lnum or 0,
      left.col or 0,
      left.end_lnum or 0,
      left.end_col or 0,
      left.message or "",
      left.source or "",
    }
    local right_key = {
      right.lnum or 0,
      right.col or 0,
      right.end_lnum or 0,
      right.end_col or 0,
      right.message or "",
      right.source or "",
    }
    for index = 1, #left_key do
      if left_key[index] ~= right_key[index] then
        return left_key[index] < right_key[index]
      end
    end
    return false
  end)

  local result = {}
  for index = 1, math.min(#values, limit) do
    local item = values[index]
    table.insert(result, {
      location = diagnostic_location(buffer, item),
      severity = severity_name(item.severity),
      message = item.message or "",
      source = item.source,
      code = item.code == nil and nil or tostring(item.code),
    })
  end
  return result
end

local function quickfix_tool(input)
  input = input or {}
  local limit = bounded_integer(input.limit, 100, 500, "limit")
  local result = {}
  for _, item in ipairs(vim.fn.getqflist()) do
    local item_location = quickfix_location(item)
    if item_location ~= nil then
      table.insert(result, {
        location = item_location,
        text = item.text or "",
        type = type(item.type) == "string" and item.type ~= "" and item.type or nil,
      })
      if #result >= limit then
        break
      end
    end
  end
  return result
end

local function viewport_tool(input)
  input = input or {}
  local max_bytes = bounded_integer(input.max_bytes, 65536, 262144, "max_bytes")
  local window = vim.api.nvim_get_current_win()
  local buffer = vim.api.nvim_win_get_buf(window)
  local top = math.max(0, vim.fn.line("w0", window) - 1)
  local bottom = math.max(top, vim.fn.line("w$", window) - 1)
  local lines = vim.api.nvim_buf_get_lines(buffer, top, bottom + 1, false)
  local text, truncated = utf8_prefix(table.concat(lines, "\n"), max_bytes)
  local last = lines[#lines] or ""
  return {
    location = {
      uri = buffer_uri(buffer),
      range = {
        start = { line = top, column = 0 },
        ["end"] = { line = bottom, column = #last },
      },
    },
    text = text,
    truncated = truncated,
  }
end

local default_tools = {
  {
    definition = {
      id = "nvim.context.current_location",
      description = "Return the current Neovim cursor location.",
      input = unit,
      output = location,
      requires_permission = false,
    },
    handler = current_location_tool,
  },
  {
    definition = {
      id = "nvim.context.selection",
      description = "Return the current visual selection when one is active.",
      input = unit,
      output = option(selection_snapshot),
      requires_permission = false,
    },
    handler = selection_tool,
  },
  {
    definition = {
      id = "nvim.context.buffer",
      description = "Return a bounded snapshot of the current or named loaded Neovim buffer.",
      input = record({
        uri = option(string_type),
        max_bytes = option(u64),
      }),
      output = buffer_snapshot,
      requires_permission = false,
    },
    handler = buffer_tool,
  },
  {
    definition = {
      id = "nvim.context.buffers",
      description = "List loaded Neovim buffers.",
      input = unit,
      output = list(buffer_info),
      requires_permission = false,
    },
    handler = buffers_tool,
  },
  {
    definition = {
      id = "nvim.context.diagnostics",
      description = "Return bounded diagnostics for the current or named loaded Neovim buffer.",
      input = record({
        uri = option(string_type),
        limit = option(u64),
      }),
      output = list(diagnostic),
      requires_permission = false,
    },
    handler = diagnostics_tool,
  },
  {
    definition = {
      id = "nvim.context.quickfix",
      description = "Return bounded Neovim quickfix entries.",
      input = record({
        limit = option(u64),
      }),
      output = list(quickfix_item),
      requires_permission = false,
    },
    handler = quickfix_tool,
  },
  {
    definition = {
      id = "nvim.context.viewport",
      description = "Return a bounded snapshot of the visible Neovim viewport.",
      input = record({
        max_bytes = option(u64),
      }),
      output = viewport,
      requires_permission = false,
    },
    handler = viewport_tool,
  },
}

local function validate_definition(definition)
  if type(definition) ~= "table" then
    error("Phenix tool definition must be a table")
  end
  if type(definition.id) ~= "string" or definition.id == "" then
    error("Phenix tool id must be a non-empty string")
  end
  if type(definition.description) ~= "string" or definition.description == "" then
    error("Phenix tool description must be a non-empty string")
  end
  if type(definition.input) ~= "table" or type(definition.output) ~= "table" then
    error("Phenix tool input and output must be schemas")
  end
  if definition.requires_permission ~= nil and type(definition.requires_permission) ~= "boolean" then
    error("Phenix tool requires_permission must be boolean")
  end
end

function M.register(definition, handler)
  validate_definition(definition)
  if type(handler) ~= "function" then
    error("Phenix tool handler must be a function")
  end
  if templates[definition.id] ~= nil then
    error("Phenix tool already registered: " .. definition.id)
  end

  local id = definition.id
  templates[id] = {
    definition = vim.deepcopy(definition),
    handler = handler,
  }
  revision = revision + 1

  local stopped = false
  return function()
    if stopped then
      return
    end
    stopped = true
    if templates[id] ~= nil then
      templates[id] = nil
      revision = revision + 1
    end
  end
end

function M.enable_defaults()
  for _, tool in ipairs(default_tools) do
    local id = tool.definition.id
    if default_stops[id] == nil then
      default_stops[id] = M.register(tool.definition, tool.handler)
    end
  end
end

function M.disable_defaults()
  for id, stop in pairs(default_stops) do
    stop()
    default_stops[id] = nil
  end
end

function M._revision()
  return revision
end

function M._templates()
  local result = {}
  for id, template in pairs(templates) do
    table.insert(result, {
      id = id,
      definition = vim.deepcopy(template.definition),
      handler = template.handler,
    })
  end
  table.sort(result, function(left, right)
    return left.id < right.id
  end)
  return result
end

function M._schemas()
  return {
    position = position,
    range = range,
    location = location,
    selection_snapshot = selection_snapshot,
    buffer_info = buffer_info,
    buffer_snapshot = buffer_snapshot,
    diagnostic = diagnostic,
    quickfix_item = quickfix_item,
    viewport = viewport,
  }
end

return M
