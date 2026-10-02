local disclosure = require("phenix_nvim.disclosure")
local runtime = require("phenix_nvim.runtime")
local util = require("phenix_nvim.util")

local M = {}
local namespace = vim.api.nvim_create_namespace("phenix-logs")
local views = {}
local next_buffer_id = 0
local attach
local load

local function inspect_lines(value)
  return vim.split(vim.inspect(value), "\n", { plain = true })
end

local function short_digest(value)
  local digest = type(value) == "table" and value.digest or nil
  if type(digest) ~= "string" then
    return "reference"
  end
  local body = digest:gsub("^sha256:", "")
  return "sha256:" .. body:sub(1, 12)
end

local function is_reference(value)
  return type(value) == "table"
    and type(value.digest) == "string"
    and type(value.media_type) == "string"
    and type(value.bytes) == "number"
    and type(value.locator) == "table"
end

local function collect_references(value, output, seen)
  output = output or {}
  seen = seen or {}
  if type(value) ~= "table" or seen[value] then
    return output
  end
  seen[value] = true
  if is_reference(value) then
    table.insert(output, value)
    return output
  end
  for _, child in pairs(value) do
    collect_references(child, output, seen)
  end
  return output
end

local function collect_correlation(value, found, seen)
  found = found or {}
  seen = seen or {}
  if type(value) ~= "table" or seen[value] then
    return found
  end
  seen[value] = true
  for key, child in pairs(value) do
    if (key == "session_id" or key == "execution_id")
      and type(child) == "string"
      and child ~= ""
      and found[key] == nil
    then
      found[key] = child
    elseif type(child) == "table" then
      collect_correlation(child, found, seen)
    end
  end
  return found
end

local summary_keys = {
  "event",
  "source",
  "severity",
  "outcome",
  "callable_id",
  "execution_id",
  "session_id",
  "message",
}

local function scalar(value)
  local kind = type(value)
  if kind == "number" or kind == "boolean" then
    return tostring(value)
  end
  if kind ~= "string" then
    return nil
  end
  local normalized = value:gsub("%s+", " ")
  local limit = 160
  if vim.fn.strchars(normalized) <= limit then
    return normalized
  end
  return vim.fn.strcharpart(normalized, 0, limit) .. "…"
end

local function compact_summary(payload)
  if type(payload) ~= "table" then
    return scalar(payload)
  end
  local source = type(payload.summary) == "table" and payload.summary or payload
  local parts = {}
  for _, key in ipairs(summary_keys) do
    local value = scalar(source[key])
    if value ~= nil and value ~= "" then
      table.insert(parts, key .. "=" .. value)
    end
  end
  if #parts == 0 then
    local keys = vim.tbl_keys(source)
    table.sort(keys, function(left, right) return tostring(left) < tostring(right) end)
    for _, key in ipairs(keys) do
      local value = scalar(source[key])
      if value ~= nil then
        table.insert(parts, tostring(key) .. "=" .. value)
        if #parts == 3 then
          break
        end
      end
    end
  end
  return #parts > 0 and table.concat(parts, "  ") or nil
end

local function timestamp(value)
  local milliseconds = tonumber(value)
  if milliseconds == nil then
    return "unknown-time"
  end
  local seconds = math.floor(milliseconds / 1000)
  local millis = math.floor(milliseconds % 1000)
  return os.date("%H:%M:%S", seconds) .. string.format(".%03d", millis)
end

local function record_id(record)
  return "record:" .. tostring(record.cursor or "?")
end

local function headline_group(record)
  local kind = string.lower(tostring(record.kind or ""))
  local payload = record.payload
  local severity = type(payload) == "table" and string.lower(tostring(payload.severity or "")) or ""
  if kind:find("fail", 1, true) or kind:find("error", 1, true) or severity == "error" then
    return "DiagnosticError"
  end
  if kind:find("tool", 1, true) then
    return "Identifier"
  end
  if kind:find("model", 1, true) then
    return "Special"
  end
  return "Title"
end

local function ensure_buffer(view)
  if view.buffer ~= nil and vim.api.nvim_buf_is_valid(view.buffer) then
    return view.buffer
  end
  next_buffer_id = next_buffer_id + 1
  local buffer = vim.api.nvim_create_buf(false, true)
  view.buffer = buffer
  vim.bo[buffer].buftype = "nofile"
  vim.bo[buffer].bufhidden = "wipe"
  vim.bo[buffer].swapfile = false
  vim.bo[buffer].modifiable = false
  vim.bo[buffer].filetype = "markdown"
  vim.bo[buffer].undolevels = -1
  vim.b[buffer].phenix_internal = true
  vim.b[buffer].phenix_role = "logs"
  vim.api.nvim_buf_set_name(buffer, "phenix://logs/" .. tostring(next_buffer_id))
  views[buffer] = view
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buffer,
    once = true,
    callback = function()
      views[buffer] = nil
    end,
  })
  return buffer
end

local function scope_title(view)
  if view.execution_id ~= nil then
    return "execution " .. view.execution_id
  end
  if view.session_id ~= nil then
    return "session " .. view.session_id
  end
  return "all"
end

local function add_line(lines, line)
  table.insert(lines, line)
  return #lines
end

local function render(view)
  local buffer = ensure_buffer(view)
  local lines = {
    "# Phenix logs · " .. scope_title(view),
    "",
    "<CR> details · gf/gF content · gd session/execution · ]l load more",
    "",
  }
  local row_to_record = {}
  local row_to_reference = {}
  local row_to_scope = {}
  local record_starts = {}
  local headline_rows = {}

  for _, record in ipairs(view.records) do
    local id = record_id(record)
    local open = disclosure.is_open(view.disclosure, id)
    local start = add_line(
      lines,
      (open and "▼ " or "▶ ")
        .. timestamp(record.timestamp_ms)
        .. "  "
        .. tostring(record.kind or "record")
        .. "  #"
        .. tostring(record.cursor or "?")
    )
    record_starts[id] = start
    headline_rows[start] = headline_group(record)
    row_to_record[start] = id

    local summary = compact_summary(record.payload)
    if summary ~= nil then
      local row = add_line(lines, "  " .. summary)
      row_to_record[row] = id
    end

    for _, reference in ipairs(collect_references(record.payload)) do
      local row = add_line(
        lines,
        "  ↳ "
          .. short_digest(reference)
          .. "  "
          .. tostring(reference.media_type or "")
          .. "  gf"
      )
      row_to_record[row] = id
      row_to_reference[row] = reference
    end

    local correlation = collect_correlation(record.payload)
    if correlation.execution_id ~= nil then
      local row = add_line(lines, "  ↳ execution " .. correlation.execution_id .. "  gd")
      row_to_record[row] = id
      row_to_scope[row] = {
        session_id = correlation.session_id,
        execution_id = correlation.execution_id,
      }
    elseif correlation.session_id ~= nil then
      local row = add_line(lines, "  ↳ session " .. correlation.session_id .. "  gd")
      row_to_record[row] = id
      row_to_scope[row] = { session_id = correlation.session_id }
    end

    if open then
      add_line(lines, "")
      local label = add_line(lines, "  Payload")
      row_to_record[label] = id
      for _, line in ipairs(inspect_lines(record.payload)) do
        local row = add_line(lines, "  " .. line)
        row_to_record[row] = id
      end
    end
    local blank = add_line(lines, "")
    row_to_record[blank] = id
  end

  if #view.records == 0 then
    add_line(lines, "No matching log records.")
  elseif view.next_cursor ~= nil then
    add_line(lines, "… more records available · ]l")
  end

  vim.bo[buffer].modifiable = true
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(buffer, namespace, 0, -1)
  for row, group in pairs(headline_rows) do
    vim.api.nvim_buf_add_highlight(buffer, namespace, group, row - 1, 0, -1)
  end
  for row in pairs(row_to_reference) do
    vim.api.nvim_buf_add_highlight(buffer, namespace, "Underlined", row - 1, 2, -1)
  end
  vim.bo[buffer].modifiable = false

  view.row_to_record = row_to_record
  view.row_to_reference = row_to_reference
  view.row_to_scope = row_to_scope
  view.record_starts = record_starts
end

local function open_view(view)
  local buffer = ensure_buffer(view)
  vim.cmd("tabnew")
  vim.api.nvim_win_set_buf(0, buffer)
  attach(buffer)
  render(view)
  return buffer
end

local function current_view()
  return views[vim.api.nvim_get_current_buf()]
end

local function toggle()
  local view = current_view()
  if view == nil then
    return
  end
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local id = view.row_to_record[row]
  if id == nil then
    return
  end
  disclosure.toggle(view.disclosure, id)
  render(view)
  local target = view.record_starts[id]
  if target ~= nil then
    pcall(vim.api.nvim_win_set_cursor, 0, { target, 0 })
  end
end

local function open_reference_buffer(reference, content)
  local view = {
    records = {
      {
        cursor = short_digest(reference),
        timestamp_ms = nil,
        kind = "referenced object",
        payload = content,
      },
    },
    next_cursor = nil,
    disclosure = disclosure.new(),
    session_id = nil,
    execution_id = nil,
  }
  local buffer = ensure_buffer(view)
  vim.cmd("tabnew")
  vim.api.nvim_win_set_buf(0, buffer)
  attach(buffer)
  render(view)
end

local function follow_reference()
  local view = current_view()
  if view == nil then
    return
  end
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local reference = view.row_to_reference[row]
  if reference == nil then
    return
  end
  runtime.log_reference(reference, function(result, error)
    if error ~= nil then
      util.notify(vim.inspect(error), vim.log.levels.ERROR)
      return
    end
    local content = result and result.content or ""
    local decoded = nil
    if type(content) == "string"
      and type(reference.media_type) == "string"
      and reference.media_type:find("json", 1, true)
    then
      local ok, value = pcall(vim.json.decode, content)
      if ok then
        decoded = value
      end
    end
    open_reference_buffer(reference, decoded or content)
  end)
end

local function follow_scope()
  local view = current_view()
  if view == nil then
    return
  end
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local target = view.row_to_scope[row]
  if target == nil then
    follow_reference()
    return
  end
  local next_view = {
    buffer = nil,
    records = {},
    next_cursor = nil,
    disclosure = disclosure.new(),
    session_id = target.session_id,
    execution_id = target.execution_id,
    row_to_record = {},
    row_to_reference = {},
    row_to_scope = {},
    record_starts = {},
    loading = false,
  }
  open_view(next_view)
  load(next_view, false)
end

attach = function(buffer)
  vim.keymap.set("n", "<CR>", toggle, {
    buffer = buffer,
    silent = true,
    desc = "Toggle Phenix log details",
  })
  for _, key in ipairs({ "gf", "gF" }) do
    vim.keymap.set("n", key, follow_reference, {
      buffer = buffer,
      silent = true,
      desc = "Open Phenix log content reference",
    })
  end
  vim.keymap.set("n", "gd", follow_scope, {
    buffer = buffer,
    silent = true,
    desc = "Open correlated Phenix logs",
  })
  vim.keymap.set("n", "]l", function()
    M.more()
  end, {
    buffer = buffer,
    silent = true,
    desc = "Load more Phenix log records",
  })
  local win = vim.fn.bufwinid(buffer)
  if win > 0 then
    vim.wo[win].wrap = true
    vim.wo[win].linebreak = true
    vim.wo[win].breakindent = true
    vim.wo[win].scrolloff = 0
    if vim.fn.exists("+smoothscroll") == 1 then
      vim.wo[win].smoothscroll = true
    end
  end
end

local function query_options(view)
  return {
    cursor = view.next_cursor,
    limit = 200,
    session_id = view.session_id,
    execution_id = view.execution_id,
  }
end

load = function(view, append)
  if view.loading then
    return
  end
  view.loading = true
  runtime.logs(query_options(view), function(result, error)
    view.loading = false
    if error ~= nil then
      util.notify(vim.inspect(error), vim.log.levels.ERROR)
      return
    end
    if view.buffer == nil or not vim.api.nvim_buf_is_valid(view.buffer) then
      return
    end
    local records = result and result.records or {}
    if append then
      vim.list_extend(view.records, records)
    else
      view.records = vim.deepcopy(records)
    end
    view.next_cursor = result and result.next_cursor or nil
    render(view)
  end)
end

function M.more()
  local view = current_view()
  if view == nil or view.next_cursor == nil then
    return
  end
  load(view, true)
end

function M.open(scope)
  scope = scope or "session"
  local session_id
  local execution_id
  if scope == "session" or scope == "execution" then
    session_id = runtime.active_session()
    if session_id == nil then
      util.notify("No active Phenix session", vim.log.levels.WARN)
      return
    end
  end
  if scope == "execution" then
    execution_id = runtime.status(session_id).execution_id
    if execution_id == nil then
      util.notify("The active Phenix session has no execution", vim.log.levels.WARN)
      return
    end
  elseif scope ~= "session" and scope ~= "all" then
    util.notify("Usage: Phenix logs [session|execution|all]", vim.log.levels.ERROR)
    return
  end

  local view = {
    buffer = nil,
    records = {},
    next_cursor = nil,
    disclosure = disclosure.new(),
    session_id = session_id,
    execution_id = execution_id,
    row_to_record = {},
    row_to_reference = {},
    row_to_scope = {},
    record_starts = {},
    loading = false,
  }
  open_view(view)
  load(view, false)
end

return M
