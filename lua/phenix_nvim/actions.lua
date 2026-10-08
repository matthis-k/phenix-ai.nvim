local clipboard = require("phenix_nvim.clipboard")
local compose = require("phenix_nvim.compose.buffer")
local compose_model = require("phenix_nvim.compose.model")
local context = require("phenix_nvim.context")
local image = require("phenix_nvim.image")
local logs = require("phenix_nvim.logs")
local runtime = require("phenix_nvim.runtime")
local sessions = require("phenix_nvim.sessions")
local sidebar = require("phenix_nvim.sidebar")
local state = require("phenix_nvim.state")
local util = require("phenix_nvim.util")

local M = {}
local submissions = setmetatable({}, { __mode = "k" })
local active_runs = setmetatable({}, { __mode = "k" })
local paused_queues = setmetatable({}, { __mode = "k" })
local queued = setmetatable({}, { __mode = "k" })
local queue_view = require("phenix_nvim.queue")
local prompt_connection_state = runtime.status().connection
local prompt_connection_generation = 0

local function target_surface(options)
  options = options or {}
  local surface = options.document and sidebar.surface_for_document(options.document) or sidebar.current_surface()
  if surface == nil then
    surface = sidebar.open()
  end
  return surface
end

local function insert(item, options)
  local surface = target_surface(options)
  if surface == nil then
    util.notify("could not open Phenix chat window", vim.log.levels.ERROR)
    return nil
  end
  local document = options and options.document or surface.compose
  local win = sidebar.focus_compose(surface)
  local stored = compose_model.add(document, item)
  local inserted, error = compose.insert(document, stored, win)
  if not inserted then
    compose_model.remove(document, stored.id)
    util.notify(error or "could not insert compose attachment", vim.log.levels.ERROR)
    return nil
  end
  return stored
end

function M.reference()
  local mode = vim.fn.mode(1)
  local item, error
  if mode == "v" or mode == "V" or mode == "\22" then
    item, error = context.visual_selection()
  else
    item = context.current_location()
  end
  if item == nil then
    util.notify(error, vim.log.levels.ERROR)
    return
  end
  insert(item)
end

function M.reference_range(start_line, end_line)
  insert(context.line_selection(start_line, end_line))
end

function M.reference_at(value)
  local item, error = context.typed_reference(value)
  if item == nil then
    util.notify(error, vim.log.levels.ERROR)
    return
  end
  insert(item)
end

function M.reference_picker()
  context.pick_reference(function(item, error)
    if error ~= nil then
      util.notify(vim.inspect(error), vim.log.levels.ERROR)
      return
    end
    if item ~= nil then
      insert(item)
    end
  end)
end

local function attach_image_file(path, temporary, options)
  options = options or {}
  local item, error = image.from_file(path)
  if temporary then
    os.remove(path)
  end
  if item == nil then
    if not options.quiet then
      util.notify(error, vim.log.levels.ERROR)
    end
    return nil
  end
  if temporary then
    item.path = nil
  end
  return insert(item, options)
end

function M.attach_image(source, options)
  options = options or {}
  source = (source == nil or source == "") and "clipboard" or source
  if source == "clipboard" then
    local path, error = clipboard.temp_image_file()
    if path == nil then
      if not options.quiet then
        util.notify(error or "clipboard does not contain a supported image", vim.log.levels.ERROR)
      end
      return nil
    end
    return attach_image_file(path, true, options)
  end
  return attach_image_file(source, false, options)
end

local function snapshot_revision(document)
  local buffer = compose.ensure(document)
  return tostring(document.revision) .. ":" .. tostring(vim.api.nvim_buf_get_changedtick(buffer))
end

local function message_kind(value)
  if type(value) == "table" then
    return string.lower(tostring(value.kind or ""))
  end
  return string.lower(tostring(value or ""))
end

local function normalized_content(content)
  local result = {}
  for _, part in ipairs(content or {}) do
    local kind = message_kind(part.kind)
    if kind == "text" then
      table.insert(result, { kind = "text", text = part.text or "" })
    elseif kind == "resource" or kind == "location" or kind == "selection" then
      local source = part.source or {}
      table.insert(result, {
        kind = "resource",
        uri = part.uri or source.uri,
        text = part.snapshot or part.text,
      })
    elseif kind == "image" then
      table.insert(result, {
        kind = "image",
        mime_type = part.mime_type,
        data = part.bytes or part.data,
      })
    end
  end
  return result
end

local function transcript_contains_submission(projection, pending)
  if type(projection) ~= "table" or type(projection.updates) ~= "table" then
    return false
  end
  local expected = normalized_content(pending.content)
  for _, item in ipairs(projection.updates) do
    if type(item.sequence) == "number" and item.sequence > pending.after_sequence then
      local change = item.update or {}
      if message_kind(change.kind) == "message" then
        local message = change.message or {}
        if message_kind(message.role) == "user"
          and vim.deep_equal(normalized_content(message.content), expected)
        then
          return true
        end
      end
    end
  end
  return false
end

local function acknowledge(document, pending, projection)
  if pending.confirmed or not transcript_contains_submission(projection, pending) then
    return
  end
  pending.confirmed = true
  if submissions[document] == pending then
    submissions[document] = nil
  end
  -- Preserve text or attachments edited after send.
  if snapshot_revision(document) == pending.revision then
    compose.clear(document)
  end
end

runtime.on_event(function(kind, value)
  if kind ~= "sessions" then
    return
  end
  local sessions = type(value) == "table" and value.sessions or {}
  for document, pending in pairs(submissions) do
    if pending.session_id ~= nil then
      acknowledge(document, pending, sessions[pending.session_id])
    end
  end
end)

local function queue_for(surface)
  if queued[surface] == nil then
    queued[surface] = {}
  end
  return queued[surface]
end

local dispatch_next

local function render_queue(surface)
  local entries = queue_for(surface)
  if #entries == 0 then
    paused_queues[surface] = nil
  end
  queue_view.render(surface, entries, function(index)
    table.remove(entries, index)
    render_queue(surface)
  end, function()
    paused_queues[surface] = nil
    dispatch_next(surface)
  end)
end

runtime.on_event(function(kind, status)
  if kind ~= "status" then
    return
  end
  local next_state = status.connection
  if prompt_connection_state == "ready" and next_state ~= "ready" then
    prompt_connection_generation = prompt_connection_generation + 1
    for surface, pending in pairs(active_runs) do
      pending.abandoned = true
      active_runs[surface] = nil
      if submissions[surface.compose] == pending then
        submissions[surface.compose] = nil
      end
      local entries = queue_for(surface)
      if pending.queued_item ~= nil and not pending.confirmed then
        table.insert(entries, 1, pending.queued_item)
      end
      if #entries > 0 then
        paused_queues[surface] = true
        render_queue(surface)
      end
    end
  end
  prompt_connection_state = next_state
end)

local function submit(surface, content, revision, queued_item)
  local document = surface.compose
  local session_id = surface.session_id
  local projection = runtime.session_state()
  local snapshot = projection and projection.sessions and projection.sessions[session_id]
  local pending = {
    revision = revision,
    session_id = session_id,
    content = vim.deepcopy(content),
    after_sequence = snapshot and (snapshot.through_sequence or 0) or 0,
    confirmed = false,
    queued_item = queued_item,
  }
  active_runs[surface] = pending
  if queued_item == nil then
    submissions[document] = pending
  end
  runtime.prompt(session_id, content, function(_, error)
    if pending.abandoned then
      return
    end
    local latest = runtime.session_state()
    local current = latest and latest.sessions and latest.sessions[session_id]
    acknowledge(document, pending, current)
    if submissions[document] == pending then
      submissions[document] = nil
    end
    if error ~= nil then
      util.notify(vim.inspect(error), vim.log.levels.ERROR)
    elseif not pending.confirmed then
      util.notify("Prompt finished without a matching transcript entry; draft preserved", vim.log.levels.WARN)
    end
    if active_runs[surface] == pending then
      active_runs[surface] = nil
      if error ~= nil and not pending.confirmed then
        if queued_item ~= nil then
          table.insert(queue_for(surface), 1, queued_item)
        end
        if #queue_for(surface) > 0 then
          paused_queues[surface] = true
          render_queue(surface)
          util.notify("Follow-up queue paused after rejected prompt; press r in the queue to retry", vim.log.levels.WARN)
        else
          paused_queues[surface] = nil
        end
      else
        dispatch_next(surface)
      end
    end
  end)
end

dispatch_next = function(surface)
  if active_runs[surface] ~= nil or paused_queues[surface] then
    return
  end
  local entries = queue_for(surface)
  local next_item = entries[1]
  if next_item == nil then
    render_queue(surface)
    return
  end
  if next_item.session_id ~= surface.session_id then
    util.notify("Queued follow-ups belong to a different session; queue paused", vim.log.levels.WARN)
    return
  end
  table.remove(entries, 1)
  render_queue(surface)
  submit(surface, next_item.content, nil, next_item)
end

function M.send(options)
  local surface = target_surface(options)
  if surface == nil then
    return
  end
  local document = options and options.document or surface.compose
  if document ~= surface.compose then
    surface = sidebar.surface_for_document(document)
    if surface == nil then
      util.notify("compose document is not attached to a Phenix chat window", vim.log.levels.ERROR)
      return
    end
  end

  local content, error = compose.serialize(document)
  if content == nil then
    util.notify(error, vim.log.levels.ERROR)
    return
  end
  if #content == 0 or (#content == 1 and content[1].kind == "text" and content[1].text == "") then
    util.notify("compose buffer is empty", vim.log.levels.WARN)
    return
  end
  local revision = snapshot_revision(document)
  local previous = submissions[document]
  if previous ~= nil and previous.revision == revision then
    util.notify("this compose revision is already being sent", vim.log.levels.WARN)
    return
  end
  if active_runs[surface] ~= nil or paused_queues[surface] then
    table.insert(queue_for(surface), {
      session_id = surface.session_id,
      content = vim.deepcopy(content),
    })
    render_queue(surface)
    compose.clear(document)
    return
  end
  if previous ~= nil then
    -- A session may still be opening. Preserve the new draft until it is bound.
    util.notify("Wait for the previous prompt to reach its session before sending a follow-up", vim.log.levels.WARN)
    return
  end

  if surface.session_id ~= nil then
    submit(surface, content, revision)
    return
  end
  local creating = { revision = revision, session_id = nil, confirmed = false }
  local generation = prompt_connection_generation
  submissions[document] = creating
  runtime.new_session(function(created, create_error)
    if generation ~= prompt_connection_generation then
      if submissions[document] == creating then
        submissions[document] = nil
      end
      return
    end
    if create_error ~= nil then
      if submissions[document] == creating then
        submissions[document] = nil
      end
      util.notify(vim.inspect(create_error), vim.log.levels.ERROR)
      return
    end
    local session_id = created and (created.session_id or created.id)
    if session_id == nil then
      submissions[document] = nil
      util.notify("Phenix created a session without an id", vim.log.levels.ERROR)
      return
    end
    sidebar.bind_session(session_id, surface)
    submit(surface, content, revision)
  end)
end

function M.toggle()
  sidebar.toggle()
end

function M.new(mode)
  local surface, error = sidebar.new(mode or "sidebar")
  if surface == nil and error ~= nil then
    util.notify(error, vim.log.levels.ERROR)
  end
  return surface
end


function M.logs(scope)
  logs.open(scope)
end

function M.cancel()
  runtime.cancel_active()
end

function M.new_session(callback)
  local surface = target_surface()
  sessions.new(function(value, error)
    if error == nil and surface ~= nil then
      local session_id = value and (value.session_id or value.id)
      if session_id ~= nil then
        sidebar.bind_session(session_id, surface)
      end
    end
    if callback ~= nil then
      util.safe_call(callback, value, error)
    elseif error ~= nil then
      util.notify(vim.inspect(error), vim.log.levels.ERROR)
    end
  end)
end

function M.close_session()
  local surface = target_surface()
  local session_id = surface and surface.session_id or runtime.active_session()
  sessions.close(session_id, function(_, error)
    if error ~= nil then
      util.notify(vim.inspect(error), vim.log.levels.ERROR)
      return
    end
    if surface ~= nil then
      sidebar.bind_session(nil, surface)
    end
  end)
end

function M.choose_session()
  local surface = target_surface()
  sessions.choose(function(value, error)
    if error ~= nil then
      util.notify(vim.inspect(error), vim.log.levels.ERROR)
      return
    end
    local session_id = value and (value.session_id or value.id)
    if surface ~= nil and session_id ~= nil then
      sidebar.bind_session(session_id, surface)
    end
  end)
end

local function presentation_kind(item)
  local presentation = item and item.presentation
  if type(presentation) == "table" then
    return string.lower(tostring(presentation.kind or ""))
  end
  return string.lower(tostring(presentation or ""))
end

local function choice_label(item, selected)
  local name = item.name or item.id or "unknown"
  local id = item.id
  local marker = id ~= nil and id == selected and "✓ " or "  "
  local kind = presentation_kind(item)
  local glyph = kind == "router" and "󰒍" or "󰧑"
  local tag = kind == "router" and "router" or "model"
  local label = marker .. glyph .. " [" .. tag .. "] " .. name
  if item.description ~= nil and item.description ~= "" then
    label = label .. "  ·  " .. item.description
  end
  if kind == "router" and id ~= nil and id ~= name then
    label = label .. "  ·  " .. id
  end
  return label
end

local function open_external_auth(result)
  local uri = result and result.uri
  if type(uri) ~= "string" or uri == "" then
    return false
  end
  if result.instructions ~= nil and result.instructions ~= "" then
    util.notify(result.instructions, vim.log.levels.INFO)
  end
  if type(vim.ui.open) == "function" then
    local call_ok, handle, open_error = pcall(vim.ui.open, uri)
    if call_ok and open_error == nil then
      return true
    end
    local failure = call_ok and open_error or handle
    if failure ~= nil then
      util.notify(tostring(failure), vim.log.levels.WARN)
    end
  end
  util.notify("Open this URL to finish Phenix authentication: " .. uri, vim.log.levels.INFO)
  return true
end

local auth_generation = 0
local selection_generation = 0
local connection_state = runtime.status().connection
runtime.on_event(function(kind, status)
  if kind ~= "status" then
    return
  end
  local next_state = status.connection
  if connection_state == "ready" and next_state ~= "ready" then
    auth_generation = auth_generation + 1
    selection_generation = selection_generation + 1
  end
  connection_state = next_state
end)

local AUTH_POLL_INTERVAL_MS = 1000
local AUTH_POLL_ATTEMPTS = 600

local function authentication_kind(result)
  return result and string.lower(tostring(result.kind or "")) or ""
end

local function finish_authentication(callback, value, error)
  if callback ~= nil then
    util.safe_call(callback, value, error)
  elseif error ~= nil then
    util.notify(vim.inspect(error), vim.log.levels.ERROR)
  end
end

local function poll_authentication(method, generation, attempt, callback)
  if generation ~= auth_generation then
    return
  end
  runtime.authenticate(method.id, nil, function(result, error)
    if generation ~= auth_generation then
      return
    end
    if error ~= nil then
      finish_authentication(callback, nil, error)
      return
    end
    local kind = authentication_kind(result)
    if kind == "authenticated" then
      util.notify((method.provider or "Phenix") .. " authentication completed", vim.log.levels.INFO)
      finish_authentication(callback, result, nil)
      return
    end
    if kind ~= "external" then
      finish_authentication(callback, nil, { message = "Phenix returned an unknown authentication state" })
      return
    end
    if attempt >= AUTH_POLL_ATTEMPTS then
      finish_authentication(callback, nil, { message = "Phenix authentication timed out" })
      return
    end
    vim.defer_fn(function()
      poll_authentication(method, generation, attempt + 1, callback)
    end, AUTH_POLL_INTERVAL_MS)
  end)
end

local function start_authentication(method, secret, callback)
  auth_generation = auth_generation + 1
  local generation = auth_generation
  runtime.authenticate(method.id, secret, function(result, error)
    if generation ~= auth_generation then
      return
    end
    if error ~= nil then
      finish_authentication(callback, nil, error)
      return
    end
    local kind = authentication_kind(result)
    if kind == "authenticated" then
      util.notify((method.provider or "Phenix") .. " authentication completed", vim.log.levels.INFO)
      finish_authentication(callback, result, nil)
      return
    end
    if kind ~= "external" then
      finish_authentication(callback, nil, { message = "Phenix returned an unknown authentication state" })
      return
    end
    if not open_external_auth(result) then
      finish_authentication(callback, nil, { message = "Phenix authentication did not provide a valid authorization URL" })
      return
    end
    vim.defer_fn(function()
      poll_authentication(method, generation, 1, callback)
    end, AUTH_POLL_INTERVAL_MS)
  end)
end

local function authenticate_method(method, callback)
  if string.lower(tostring(method.kind or "")) ~= "api_token" then
    start_authentication(method, nil, callback)
    return
  end
  local generation = auth_generation
  local provider = method.provider_name or method.provider or method.name or "provider"
  util.input_secret(provider .. " API key: ", function(secret, input_error)
    if generation ~= auth_generation then
      return
    end
    if input_error ~= nil then
      finish_authentication(callback, nil, input_error)
      return
    end
    if secret == nil then
      finish_authentication(callback, nil, { kind = "cancelled", message = "authentication cancelled" })
      return
    end
    if type(secret) ~= "string" or secret:match("%S") == nil then
      finish_authentication(callback, nil, { message = "API key must not be empty" })
      return
    end
    start_authentication(method, secret, callback)
  end)
end

local function authentication_label(method)
  local provider = method.provider_name or method.provider or "provider"
  local name = method.name or method.id or "authentication"
  local label = provider .. " / " .. name
  if method.description ~= nil and method.description ~= "" then
    label = label .. "  ·  " .. method.description
  end
  return label
end

local function choose_authentication_method(methods, prompt, callback)
  if #methods == 0 then
    finish_authentication(callback, nil, { message = "No Phenix authentication method is available" })
    return
  end
  if #methods == 1 then
    authenticate_method(methods[1], callback)
    return
  end
  local picker_generation = auth_generation
  vim.ui.select(methods, {
    prompt = prompt,
    format_item = authentication_label,
  }, function(method)
    if picker_generation ~= auth_generation or method == nil then
      return
    end
    authenticate_method(method, callback)
  end)
end

function M.authenticate()
  if type(runtime.list_authentication_methods) ~= "function" or type(runtime.authenticate) ~= "function" then
    util.notify("The installed Phenix runtime does not expose application authentication yet", vim.log.levels.WARN)
    return
  end
  auth_generation = auth_generation + 1
  local generation = auth_generation
  runtime.list_authentication_methods(function(result, error)
    if generation ~= auth_generation then
      return
    end
    if error ~= nil then
      util.notify(vim.inspect(error), vim.log.levels.ERROR)
      return
    end
    local methods = vim.deepcopy(result and result.methods or {})
    if #methods == 0 then
      util.notify("No Phenix authentication methods are available", vim.log.levels.WARN)
      return
    end
    vim.ui.select(methods, {
      prompt = "Phenix authentication",
      format_item = authentication_label,
    }, function(method)
      if generation ~= auth_generation or method == nil then
        return
      end
      authenticate_method(method)
    end)
  end)
end

local function model_selections(result)
  local models = {}
  local seen = {}
  for _, item in ipairs(result and result.available or {}) do
    if presentation_kind(item) == "model"
      and type(item.provider) == "string"
      and item.provider ~= ""
      and type(item.model) == "string"
      and item.model ~= ""
    then
      local thinking = item.thinking or ""
      local key = item.provider .. "\0" .. item.model .. "\0" .. thinking
      if not seen[key] then
        seen[key] = true
        table.insert(models, item)
      end
    end
  end
  table.sort(models, function(left, right)
    if left.provider ~= right.provider then
      return left.provider < right.provider
    end
    if left.model ~= right.model then
      return left.model < right.model
    end
    return tostring(left.thinking or "") < tostring(right.thinking or "")
  end)
  return models
end

local function distinct(models, field)
  local values = {}
  local seen = {}
  for _, item in ipairs(models) do
    local value = item[field]
    local key = value == nil and "\0" or tostring(value)
    if not seen[key] then
      seen[key] = true
      table.insert(values, value)
    end
  end
  table.sort(values, function(left, right)
    return tostring(left or "") < tostring(right or "")
  end)
  return values
end

local function filter_models(models, field, value)
  local filtered = {}
  for _, item in ipairs(models) do
    if item[field] == value then
      table.insert(filtered, item)
    end
  end
  return filtered
end

local function selected_marker(result, candidates)
  for _, item in ipairs(candidates) do
    if item.id == result.selected then
      return "✓ "
    end
  end
  return "  "
end

local function authenticate_provider(provider, callback)
  runtime.list_authentication_methods(function(result, error)
    if error ~= nil then
      finish_authentication(callback, nil, error)
      return
    end
    local methods = {}
    for _, method in ipairs(result and result.methods or {}) do
      if method.provider == provider then
        table.insert(methods, method)
      end
    end
    local provider_name = methods[1] and methods[1].provider_name or provider
    choose_authentication_method(methods, "Authenticate " .. provider_name, callback)
  end)
end

local function apply_model_selection(item, provider_name)
  local function select_now()
    runtime.select(item.id, function(result, error)
      if error ~= nil then
        util.notify(vim.inspect(error), vim.log.levels.ERROR)
        return
      end
      local label = (provider_name or item.provider) .. " / " .. item.model
      if item.thinking ~= nil and item.thinking ~= "" then
        label = label .. " / " .. item.thinking
      end
      util.notify(label, vim.log.levels.INFO)
    end)
  end

  if item.authenticated ~= false then
    select_now()
    return
  end
  authenticate_provider(item.provider, function(_, error)
    if error ~= nil then
      if error.kind ~= "cancelled" then
        util.notify(vim.inspect(error), vim.log.levels.ERROR)
      end
      return
    end
    select_now()
  end)
end

local function choose_thinking(result, models, provider, provider_name, model, generation)
  local variants = filter_models(filter_models(models, "provider", provider), "model", model)
  if #variants == 1 then
    apply_model_selection(variants[1], provider_name)
    return
  end
  vim.ui.select(variants, {
    prompt = "Thinking for " .. model,
    format_item = function(item)
      local label = item.thinking or "default"
      return (item.id == result.selected and "✓ " or "  ") .. label
    end,
  }, function(item)
    if generation ~= selection_generation then
      return
    end
    if item ~= nil then
      apply_model_selection(item, provider_name)
    end
  end)
end

local function choose_model(result, models, provider, provider_name, generation)
  local provider_models = filter_models(models, "provider", provider)
  local names = distinct(provider_models, "model")
  vim.ui.select(names, {
    prompt = "Model for " .. provider_name,
    format_item = function(model)
      local variants = filter_models(provider_models, "model", model)
      return selected_marker(result, variants) .. model
    end,
  }, function(model)
    if generation ~= selection_generation then
      return
    end
    if model ~= nil then
      choose_thinking(result, models, provider, provider_name, model, generation)
    end
  end)
end

local function provider_authentication_methods(methods, provider)
  local matches = {}
  for _, method in ipairs(methods or {}) do
    if method.provider == provider then
      table.insert(matches, method)
    end
  end
  return matches
end

local function provider_display_name(methods, models, provider)
  for _, item in ipairs(models or {}) do
    if item.provider == provider
      and type(item.provider_name) == "string"
      and item.provider_name ~= ""
    then
      return item.provider_name
    end
  end
  for _, method in ipairs(methods or {}) do
    if method.provider == provider
      and type(method.provider_name) == "string"
      and method.provider_name ~= ""
    then
      return method.provider_name
    end
  end
  return provider
end

local function provider_choices(models, methods)
  local providers = distinct(models, "provider")
  local seen = {}
  for _, provider in ipairs(providers) do
    seen[provider] = true
  end
  for _, method in ipairs(methods or {}) do
    local provider = method.provider
    if type(provider) == "string" and provider ~= "" and not seen[provider] then
      seen[provider] = true
      table.insert(providers, provider)
    end
  end
  table.sort(providers)
  return providers
end

local function provider_needs_authentication(methods)
  if #methods == 0 then
    return false
  end
  for _, method in ipairs(methods) do
    if method.authenticated == true then
      return false
    end
  end
  return true
end

local function continue_provider_selection(provider, provider_name, generation)
  runtime.list_selections(function(result, error)
    if generation ~= selection_generation then
      return
    end
    if error ~= nil then
      util.notify(vim.inspect(error), vim.log.levels.ERROR)
      return
    end
    local models = filter_models(model_selections(result), "provider", provider)
    if #models == 0 then
      util.notify("Phenix did not discover any models for " .. provider_name, vim.log.levels.WARN)
      return
    end
    choose_model(result, models, provider, provider_name, generation)
  end)
end

function M.choose_selection()
  selection_generation = selection_generation + 1
  local generation = selection_generation
  runtime.list_selections(function(result, error)
    if generation ~= selection_generation then
      return
    end
    if error ~= nil then
      util.notify(vim.inspect(error), vim.log.levels.ERROR)
      return
    end
    runtime.list_authentication_methods(function(auth_result, auth_error)
      if generation ~= selection_generation then
        return
      end
      if auth_error ~= nil then
        util.notify(vim.inspect(auth_error), vim.log.levels.ERROR)
        return
      end

      local models = model_selections(result)
      local methods = auth_result and auth_result.methods or {}
      local providers = provider_choices(models, methods)
      if #providers == 0 then
        util.notify("No Phenix model providers are available", vim.log.levels.WARN)
        return
      end

      vim.ui.select(providers, {
        prompt = "Phenix provider",
        format_item = function(provider)
          local candidates = filter_models(models, "provider", provider)
          local auth_methods = provider_authentication_methods(methods, provider)
          local requires_auth = provider_needs_authentication(auth_methods)
          local suffix = requires_auth and "  ·  authentication required" or ""
          return selected_marker(result, candidates) .. provider_display_name(auth_methods, candidates, provider) .. suffix
        end,
      }, function(provider)
        if generation ~= selection_generation or provider == nil then
          return
        end
        local candidates = filter_models(models, "provider", provider)
        local auth_methods = provider_authentication_methods(methods, provider)
        local provider_name = provider_display_name(auth_methods, candidates, provider)
        if provider_needs_authentication(auth_methods) then
          choose_authentication_method(auth_methods, "Authenticate " .. provider_name, function(_, auth_error_value)
            if generation ~= selection_generation then
              return
            end
            if auth_error_value ~= nil then
              if auth_error_value.kind ~= "cancelled" then
                util.notify(vim.inspect(auth_error_value), vim.log.levels.ERROR)
              end
              return
            end
            continue_provider_selection(provider, provider_name, generation)
          end)
          return
        end
        if #candidates == 0 then
          util.notify("Phenix did not discover any models for " .. provider_name, vim.log.levels.WARN)
          return
        end
        choose_model(result, models, provider, provider_name, generation)
      end)
    end)
  end)
end
return M
