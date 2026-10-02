local config = require("phenix_nvim.config")
local util = require("phenix_nvim.util")

local M = {}
local namespace = vim.api.nvim_create_namespace("phenix-log-inspector")
local buffers = {}

local categories = {
  error = { label = "ERR", group = "PhenixLogError", link = "DiagnosticError" },
  agent = { label = "AGENT", group = "PhenixLogAgent", link = "Title" },
  model = { label = "MODEL", group = "PhenixLogModel", link = "Special" },
  bash = { label = "BASH", group = "PhenixLogBash", link = "String" },
  read = { label = "READ", group = "PhenixLogRead", link = "Identifier" },
  write = { label = "WRITE", group = "PhenixLogWrite", link = "Function" },
  tool = { label = "TOOL", group = "PhenixLogTool", link = "Function" },
  policy = { label = "POLICY", group = "PhenixLogPolicy", link = "PreProc" },
  mutation = { label = "MUTATE", group = "PhenixLogMutation", link = "Type" },
  runtime = { label = "RUNTIME", group = "PhenixLogRuntime", link = "Comment" },
}

local highlight_links = {
  PhenixLogTimestamp = "Comment",
  PhenixLogReference = "Underlined",
  PhenixLogMetadata = "Comment",
  PhenixLogDetailKey = "Identifier",
}

for _, spec in pairs(categories) do
  highlight_links[spec.group] = spec.link
end

local function define_highlights()
  for group, link in pairs(highlight_links) do
    vim.api.nvim_set_hl(0, group, { default = true, link = link })
  end
end

local function env_value(runtime_config, name)
  local configured = runtime_config.env and runtime_config.env[name] or nil
  if configured ~= nil and configured ~= "" then
    return configured
  end
  local inherited = vim.env[name]
  if inherited ~= nil and inherited ~= "" then
    return inherited
  end
  return nil
end

local function sink_from_spec(spec)
  local directory = spec:match("^dir:(.+)$") or spec:match("^directory:(.+)$")
  if directory ~= nil then
    return {
      log_path = directory .. "/phenix.log",
      store_root = directory .. "/objects",
      label = directory,
    }
  end

  if spec == "stderr" or spec == "stdout" or spec == "console" then
    return nil, "Phenix logging is configured for " .. spec .. ", which has no inspectable file"
  end

  local file = spec:match("^append:(.+)$")
    or spec:match("^file:(.+)$")
    or spec:match("^truncate:(.+)$")
    or spec
  return {
    log_path = file,
    store_root = file .. ".d/objects",
    label = file,
  }
end

local function resolve_sink()
  local runtime_config = config.get()
  local spec = env_value(runtime_config, "PHENIX_DEBUG_LOG") or env_value(runtime_config, "PHENIX_LOG")
  local sink
  local sink_error
  if spec ~= nil then
    sink, sink_error = sink_from_spec(spec)
  elseif runtime_config.log_directory ~= false and runtime_config.log_directory ~= nil then
    sink, sink_error = sink_from_spec("dir:" .. runtime_config.log_directory)
  else
    return nil, "Phenix has no file-backed log directory configured"
  end
  if sink == nil then
    return nil, sink_error
  end
  local explicit_store = env_value(runtime_config, "PHENIX_LOG_STORE")
  if explicit_store ~= nil then
    sink.store_root = explicit_store
  end
  return sink
end

local function read_bytes(path)
  local handle, open_error = io.open(path, "rb")
  if handle == nil then
    return nil, open_error or ("could not open " .. path)
  end
  local content = handle:read("*a")
  handle:close()
  return content
end

local function split_lines(content)
  if content == "" then
    return {}
  end
  local lines = vim.split(content, "\n", { plain = true })
  if lines[#lines] == "" then
    table.remove(lines)
  end
  return lines
end

local function decode_json(value)
  local ok, decoded = pcall(vim.json.decode, value)
  if ok then
    return decoded
  end
  return nil
end

local function reference_from(value)
  if type(value) ~= "table" then
    return nil
  end
  if type(value.digest) ~= "string" or type(value.locator) ~= "table" then
    return nil
  end
  if type(value.locator.backend) ~= "string" then
    return nil
  end
  return value
end

local function collect_references(value, output, seen)
  if type(value) ~= "table" then
    return
  end
  local reference = reference_from(value)
  if reference ~= nil then
    local key = reference.digest .. "\0" .. tostring(reference.locator.path or reference.locator.resource or "")
    if not seen[key] then
      seen[key] = true
      table.insert(output, reference)
    end
    return
  end
  for _, child in pairs(value) do
    collect_references(child, output, seen)
  end
end

local function references(value)
  local output = {}
  collect_references(value, output, {})
  return output
end

local function safe_relative_path(path)
  if type(path) ~= "string" or path == "" or path:sub(1, 1) == "/" or path:find("\\", 1, true) ~= nil then
    return nil
  end
  for component in path:gmatch("[^/]+") do
    if component == "." or component == ".." then
      return nil
    end
  end
  return path
end

local function reference_path(reference, store_root)
  if reference == nil or reference.locator.backend ~= "file" then
    return nil, "Only file-backed Phenix content references can be opened in this inspector"
  end
  local relative = safe_relative_path(reference.locator.path)
  if relative == nil then
    return nil, "Phenix content reference has an unsafe file locator"
  end
  return store_root .. "/" .. relative
end

local function read_reference(reference, store_root)
  local path, path_error = reference_path(reference, store_root)
  if path == nil then
    return nil, path_error
  end
  local content, read_error = read_bytes(path)
  if content == nil then
    return nil, read_error
  end
  if type(reference.bytes) == "number" and #content ~= reference.bytes then
    return nil, string.format(
      "Phenix content reference length mismatch for %s: expected %d, got %d",
      reference.digest,
      reference.bytes,
      #content
    )
  end
  if reference.digest:match("^sha256:[0-9a-fA-F]+$") ~= nil then
    local ok, digest = pcall(vim.fn.sha256, content)
    if ok and type(digest) == "string" and "sha256:" .. digest:lower() ~= reference.digest:lower() then
      return nil, "Phenix content reference digest mismatch for " .. reference.digest
    end
  end
  return content, nil, path
end

local function detail_value(record, store_root)
  local payload = type(record) == "table" and record.payload or nil
  local detail = type(payload) == "table" and payload.detail or nil
  if type(detail) ~= "table" then
    return nil
  end
  if detail.kind == "inline" then
    return detail.value
  end
  if detail.kind ~= "reference" then
    return nil
  end
  local reference = reference_from(detail.reference)
  if reference == nil then
    return nil
  end
  local content = read_reference(reference, store_root)
  if content == nil then
    return nil
  end
  return decode_json(content)
end

local function walk(value, callback, depth)
  depth = depth or 0
  if depth > 8 then
    return nil
  end
  if type(value) ~= "table" then
    return nil
  end
  local matched = callback(value)
  if matched ~= nil then
    return matched
  end
  local keys = {}
  for key in pairs(value) do
    table.insert(keys, key)
  end
  table.sort(keys, function(left, right)
    return tostring(left) < tostring(right)
  end)
  for _, key in ipairs(keys) do
    local child = value[key]
    if type(child) == "table" then
      local nested = walk(child, callback, depth + 1)
      if nested ~= nil then
        return nested
      end
    end
  end
  return nil
end

local function find_field(value, names)
  return walk(value, function(object)
    for _, key in ipairs(names) do
      local child = object[key]
      if type(child) == "string" or type(child) == "number" or type(child) == "boolean" then
        return child
      end
    end
    return nil
  end)
end

local function all_text(value, output, depth)
  output = output or {}
  depth = depth or 0
  if depth > 8 then
    return output
  end
  if type(value) == "string" then
    table.insert(output, value:lower())
    return output
  end
  if type(value) ~= "table" then
    return output
  end
  for key, child in pairs(value) do
    table.insert(output, tostring(key):lower())
    all_text(child, output, depth + 1)
  end
  return output
end

local function contains_any(haystack, needles)
  for _, needle in ipairs(needles) do
    if haystack:find(needle, 1, true) ~= nil then
      return true
    end
  end
  return false
end

local function is_failure(context, kind)
  local event = tostring(find_field(context, { "event" }) or ""):lower()
  local outcome = tostring(find_field(context, { "outcome", "state", "status" }) or ""):lower()
  local success = find_field(context, { "success" })
  return success == false
    or contains_any(kind, { "error", "failed", "failure" })
    or contains_any(event, { "failed", "rejected", "error" })
    or contains_any(outcome, { "failed", "denied", "error", "cancelled" })
end

local function classify(record, context)
  if type(record) ~= "table" then
    return "error"
  end
  local kind = tostring(record.kind or ""):lower()
  local event = tostring(find_field(context, { "event" }) or ""):lower()
  local callable = tostring(find_field(context, { "callable_id", "callable" }) or ""):lower()
  local service = tostring(find_field(context, { "service" }) or ""):lower()
  local text = table.concat(all_text(context), " ")

  if contains_any(callable, { "shell", "bash" }) or contains_any(text, { "workspace.shell", "phx1_bash" }) then
    return "bash"
  end
  if callable == "read" or contains_any(callable, { ".read", "workspace.read" }) then
    return "read"
  end
  if contains_any(callable, { ".write", "workspace.write", "patch", "edit" }) then
    return "write"
  end
  if kind == "model_diagnostic"
    or contains_any(event, { "routing_decision", "dispatch_", "model_turn_" })
    or service:find("model", 1, true) ~= nil
  then
    return "model"
  end
  if contains_any(event, { "tool_call", "tool_result" }) or callable ~= "" then
    return "tool"
  end
  if contains_any(service, { "agent-loop", "execution", "delegat" }) or contains_any(text, { "execution_id", "parent_execution", "agent_loop" }) then
    return "agent"
  end
  if event == "policy_stage" or kind:find("policy", 1, true) ~= nil then
    return "policy"
  end
  if event == "data_mutation" or kind:find("mutation", 1, true) ~= nil then
    return "mutation"
  end
  if is_failure(context, kind) then
    return "error"
  end
  return "runtime"
end

local function timestamp(record)
  if type(record) ~= "table" or type(record.timestamp_ms) ~= "number" then
    return "--:--:--"
  end
  return os.date("%H:%M:%S", math.floor(record.timestamp_ms / 1000))
end

local function short_digest(reference)
  if reference == nil or type(reference.digest) ~= "string" then
    return nil
  end
  local prefix, digest = reference.digest:match("^(%w+):(.+)$")
  if prefix ~= nil and digest ~= nil then
    return prefix .. ":" .. digest:sub(1, 12)
  end
  return reference.digest:sub(1, 19)
end

local function first_non_empty(...)
  for index = 1, select("#", ...) do
    local value = select(index, ...)
    if value ~= nil and tostring(value) ~= "" then
      return tostring(value)
    end
  end
  return nil
end

local function summary(record)
  if type(record) ~= "table" then
    local spec = categories.error
    return {
      category = "error",
      chunks = {
        { "--:--:-- ", "PhenixLogTimestamp" },
        { string.format("%-7s", spec.label), spec.group },
        { " invalid JSON log record", "PhenixLogError" },
      },
      text = "invalid JSON log record",
      failure = true,
    }
  end

  local context = record
  local category = classify(record, context)
  local spec = categories[category]
  local failure = is_failure(context, tostring(record.kind or ""):lower())
  local event = find_field(context, { "event" })
  local callable = find_field(context, { "callable_id", "callable" })
  local service = find_field(context, { "service" })
  local model = find_field(context, { "model" })
  local provider = find_field(context, { "provider_plugin", "provider" })
  local execution = find_field(context, { "execution_id", "execution" })
  local policy = find_field(context, { "policy" })
  local stage = find_field(context, { "stage" })
  local outcome = find_field(context, { "outcome", "state", "status" })
  local reason = find_field(context, { "reason", "error", "message" })
  local resource = find_field(context, { "resource", "path" })

  local text
  if category == "error" then
    text = first_non_empty(reason, callable, event, service, record.kind, "failure")
  elseif category == "model" then
    text = first_non_empty(model, event, service, record.kind, "model")
    if provider ~= nil and tostring(provider) ~= "" and tostring(provider) ~= text then
      text = text .. " · " .. tostring(provider)
    end
  elseif category == "agent" then
    text = first_non_empty(execution, callable, event, service, record.kind, "execution")
  elseif category == "policy" then
    text = first_non_empty(policy, event, record.kind, "policy")
    if stage ~= nil then
      text = text .. " · " .. tostring(stage)
    end
  elseif category == "mutation" then
    text = first_non_empty(resource, event, record.kind, "mutation")
  else
    text = first_non_empty(callable, resource, service, event, record.kind, category)
  end

  local refs = references(record)
  local chunks = {
    { timestamp(record) .. " ", "PhenixLogTimestamp" },
    { string.format("%-7s", spec.label), spec.group },
    { " " .. text, "Normal" },
  }
  if outcome ~= nil and tostring(outcome) ~= "" then
    table.insert(chunks, { " · " .. tostring(outcome), failure and "PhenixLogError" or spec.group })
  elseif failure then
    table.insert(chunks, { " · failed", "PhenixLogError" })
  end
  if #refs > 0 then
    local digest = short_digest(refs[1]) or "reference"
    local suffix = #refs > 1 and (" +" .. tostring(#refs - 1)) or ""
    table.insert(chunks, { "  → " .. digest .. suffix, "PhenixLogReference" })
  end
  return {
    category = category,
    chunks = chunks,
    text = text,
    references = refs,
    failure = failure,
  }
end

local function scalar(value)
  local kind = type(value)
  return kind == "string" or kind == "number" or kind == "boolean"
end

local function detail_lines(value, output, prefix, depth, budget)
  output = output or {}
  prefix = prefix or ""
  depth = depth or 0
  budget = budget or 14
  if #output >= budget or depth > 4 or type(value) ~= "table" then
    return output
  end

  local keys = {}
  for key in pairs(value) do
    table.insert(keys, key)
  end
  table.sort(keys, function(left, right)
    return tostring(left) < tostring(right)
  end)

  for _, key in ipairs(keys) do
    if #output >= budget then
      break
    end
    local child = value[key]
    local path = prefix == "" and tostring(key) or (prefix .. "." .. tostring(key))
    local reference = reference_from(child)
    if reference ~= nil then
      table.insert(output, {
        { "    " .. path .. "  ", "PhenixLogDetailKey" },
        { short_digest(reference) or reference.digest, "PhenixLogReference" },
      })
    elseif scalar(child) then
      local rendered = tostring(child):gsub("\n", "\\n")
      if #rendered > 160 then
        rendered = rendered:sub(1, 157) .. "..."
      end
      table.insert(output, {
        { "    " .. path .. "  ", "PhenixLogDetailKey" },
        { rendered, "Normal" },
      })
    elseif type(child) == "table" then
      detail_lines(child, output, path, depth + 1, budget)
    end
  end
  return output
end

local function record_detail_lines(record, detail)
  local target = detail or record
  local lines = detail_lines(target)
  if #lines == 0 then
    return {
      { { "    no additional structured fields", "PhenixLogMetadata" } },
    }
  end
  return lines
end

local function state(buf)
  return buffers[buf]
end

local function clear_decorations(buf)
  vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1)
end

local function decorate(buf)
  local view = state(buf)
  if view == nil or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  clear_decorations(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  view.rows = {}
  view.cache = view.cache or {}
  for index, line in ipairs(lines) do
    local row = index - 1
    local cached = view.cache[line]
    local record = cached and cached.record or decode_json(line)
    local info = cached and cached.info or summary(record)
    view.cache[line] = { record = record, info = info }
    view.rows[index] = info
    if view.raw then
      vim.api.nvim_buf_set_extmark(buf, namespace, row, 0, {
        end_row = row,
        end_col = #line,
        hl_group = info.failure and "PhenixLogError" or "PhenixLogMetadata",
        hl_eol = false,
      })
    else
      local options = {
        end_row = row,
        end_col = #line,
        conceal = "",
        virt_text = info.chunks,
        virt_text_pos = "overlay",
        hl_mode = "combine",
      }
      if view.expanded[index] and record ~= nil then
        if not info.detail_loaded then
          info.detail = detail_value(record, view.store_root)
          info.detail_loaded = true
        end
        options.virt_lines = record_detail_lines(record, info.detail)
      end
      vim.api.nvim_buf_set_extmark(buf, namespace, row, 0, options)
    end
  end
end

local function configure_window(win, raw)
  if win == nil or not vim.api.nvim_win_is_valid(win) then
    return
  end
  vim.wo[win].wrap = false
  vim.wo[win].linebreak = false
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].foldcolumn = "0"
  vim.wo[win].cursorline = true
  vim.wo[win].conceallevel = raw and 0 or 2
  vim.wo[win].concealcursor = "nvic"
  vim.wo[win].winbar = raw
      and "%#Title# Phenix logs %#Comment#  RAW  R semantic  r refresh  q close"
    or "%#Title# Phenix logs %#Comment#  <CR> details  gf reference  ]e error  ]t tool  R raw"
end

local function windows_for_buffer(buf)
  local result = {}
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == buf then
      table.insert(result, win)
    end
  end
  return result
end

local function redraw(buf)
  decorate(buf)
  local view = state(buf)
  for _, win in ipairs(windows_for_buffer(buf)) do
    configure_window(win, view and view.raw or false)
  end
end

local function close_current()
  local buf = vim.api.nvim_get_current_buf()
  local view = state(buf)
  if view == nil then
    return
  end
  local parent = view.source and view.source.parent_buf or nil
  if parent ~= nil and vim.api.nvim_buf_is_valid(parent) then
    vim.api.nvim_set_current_buf(parent)
  end
  pcall(vim.api.nvim_buf_delete, buf, { force = true })
end

local function jump_category(direction, wanted)
  local buf = vim.api.nvim_get_current_buf()
  local view = state(buf)
  if view == nil then
    return
  end
  local current = vim.api.nvim_win_get_cursor(0)[1]
  local count = vim.api.nvim_buf_line_count(buf)
  local index = current + direction
  while index >= 1 and index <= count do
    local row = view.rows[index]
    local category = row and row.category or nil
    local matches = false
    for _, candidate in ipairs(wanted) do
      if category == candidate or (candidate == "error" and row and row.failure) then
        matches = true
        break
      end
    end
    if matches then
      vim.api.nvim_win_set_cursor(0, { index, 0 })
      return
    end
    index = index + direction
  end
end

local function map(buf, lhs, callback, description)
  vim.keymap.set("n", lhs, callback, {
    buffer = buf,
    silent = true,
    nowait = true,
    desc = description,
  })
end

local function attach_keymaps(buf)
  map(buf, "q", close_current, "Close Phenix log inspector")
  map(buf, "r", function()
    M.refresh(buf)
  end, "Refresh Phenix logs")
  map(buf, "R", function()
    M.toggle_raw(buf)
  end, "Toggle raw Phenix log data")
  map(buf, "<CR>", function()
    M.toggle_details(buf)
  end, "Toggle Phenix log record details")
  map(buf, "gf", function()
    M.follow_reference(buf)
  end, "Open Phenix log reference")
  map(buf, "gd", function()
    M.follow_reference(buf)
  end, "Inspect Phenix log reference")
  map(buf, "]e", function()
    jump_category(1, { "error" })
  end, "Next Phenix log error")
  map(buf, "[e", function()
    jump_category(-1, { "error" })
  end, "Previous Phenix log error")
  map(buf, "]a", function()
    jump_category(1, { "agent" })
  end, "Next Phenix agent event")
  map(buf, "[a", function()
    jump_category(-1, { "agent" })
  end, "Previous Phenix agent event")
  map(buf, "]t", function()
    jump_category(1, { "tool", "bash", "read", "write" })
  end, "Next Phenix tool event")
  map(buf, "[t", function()
    jump_category(-1, { "tool", "bash", "read", "write" })
  end, "Previous Phenix tool event")
end

local function buffer_name(source)
  if source.kind == "root" then
    return "phenix://logs"
  end
  return "phenix://logs/object/" .. source.reference.digest
end

local function existing_buffer(name)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_name(buf) == name then
      return buf
    end
  end
  return nil
end

local function set_lines(buf, lines)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
end

local function source_content(source)
  if source.kind == "root" then
    return read_bytes(source.log_path)
  end
  return read_reference(source.reference, source.store_root)
end

local function open_source(source, options)
  options = options or {}
  define_highlights()
  local name = buffer_name(source)
  local buf = existing_buffer(name)
  if buf == nil then
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, name)
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "hide"
    vim.bo[buf].swapfile = false
    vim.bo[buf].undolevels = -1
    vim.bo[buf].filetype = "phenixlog"
    buffers[buf] = {
      source = source,
      store_root = source.store_root,
      raw = options.raw == true,
      expanded = {},
      rows = {},
      cache = {},
    }
    vim.api.nvim_buf_attach(buf, false, {
      on_detach = function()
        buffers[buf] = nil
      end,
    })
    attach_keymaps(buf)
  else
    buffers[buf].source = source
    buffers[buf].store_root = source.store_root
    if options.raw ~= nil then
      buffers[buf].raw = options.raw == true
    end
  end

  local content, read_error = source_content(source)
  if content == nil then
    return nil, read_error
  end
  set_lines(buf, split_lines(content))
  vim.bo[buf].readonly = true
  redraw(buf)
  vim.api.nvim_set_current_buf(buf)
  configure_window(vim.api.nvim_get_current_win(), buffers[buf].raw)
  return buf
end

function M.open(options)
  options = options or {}
  local sink, sink_error = resolve_sink()
  if sink == nil then
    util.notify(sink_error, vim.log.levels.ERROR)
    return nil
  end
  if vim.fn.filereadable(sink.log_path) ~= 1 then
    util.notify("Phenix log does not exist yet: " .. sink.log_path, vim.log.levels.WARN)
    return nil
  end
  local buf, open_error = open_source({
    kind = "root",
    log_path = sink.log_path,
    store_root = sink.store_root,
  }, options)
  if buf == nil then
    util.notify(open_error, vim.log.levels.ERROR)
  end
  return buf
end

function M.refresh(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local view = state(buf)
  if view == nil then
    return false
  end
  local content, read_error = source_content(view.source)
  if content == nil then
    util.notify(read_error, vim.log.levels.ERROR)
    return false
  end
  local cursor = vim.api.nvim_win_get_cursor(0)
  view.cache = {}
  set_lines(buf, split_lines(content))
  redraw(buf)
  local line_count = math.max(vim.api.nvim_buf_line_count(buf), 1)
  pcall(vim.api.nvim_win_set_cursor, 0, { math.min(cursor[1], line_count), cursor[2] })
  return true
end

function M.toggle_raw(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local view = state(buf)
  if view == nil then
    return false
  end
  view.raw = not view.raw
  redraw(buf)
  return view.raw
end

function M.toggle_details(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local view = state(buf)
  if view == nil or view.raw then
    return false
  end
  local row = vim.api.nvim_win_get_cursor(0)[1]
  view.expanded[row] = not view.expanded[row]
  redraw(buf)
  return view.expanded[row]
end

local function choose_reference(items, callback)
  if #items == 1 then
    callback(items[1])
    return
  end
  vim.ui.select(items, {
    prompt = "Phenix log reference",
    format_item = function(reference)
      local location = reference.locator.path or reference.locator.resource or reference.locator.service or ""
      return reference.digest .. (location ~= "" and ("  ·  " .. location) or "")
    end,
  }, callback)
end

function M.follow_reference(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local view = state(buf)
  if view == nil then
    return false
  end
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local line = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1]
  local record = decode_json(line or "")
  local items = references(record)
  if #items == 0 then
    util.notify("This Phenix log record has no content reference", vim.log.levels.INFO)
    return false
  end
  choose_reference(items, function(reference)
    if reference == nil then
      return
    end
    local child, child_error = open_source({
      kind = "object",
      reference = reference,
      store_root = view.store_root,
      parent_buf = buf,
    }, { raw = view.raw })
    if child == nil then
      util.notify(child_error, vim.log.levels.ERROR)
    end
  end)
  return true
end

function M.category_at(buf, line)
  local view = state(buf)
  local row = view and view.rows[line] or nil
  return row and row.category or nil
end

function M.failure_at(buf, line)
  local view = state(buf)
  local row = view and view.rows[line] or nil
  return row and row.failure == true or false
end

function M.is_log_buffer(buf)
  return state(buf) ~= nil
end

return M
