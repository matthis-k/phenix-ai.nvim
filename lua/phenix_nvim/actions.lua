local compose = require("phenix_nvim.compose.buffer")
local compose_model = require("phenix_nvim.compose.model")
local config_api = require("phenix_nvim.config")
local context = require("phenix_nvim.context")
local image = require("phenix_nvim.image")
local runtime = require("phenix_nvim.runtime")
local sessions = require("phenix_nvim.sessions")
local sidebar = require("phenix_nvim.sidebar")
local state = require("phenix_nvim.state")
local util = require("phenix_nvim.util")

local M = {}

local function insert(item)
  local stored = compose_model.add(state.compose, item)
  local win = sidebar.focus_compose()
  compose.insert(state.compose, stored, win)
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

function M.attach_image(path)
  local function attach(value)
    if value == nil or value == "" then
      return
    end
    local item, error = image.from_file(value)
    if item == nil then
      util.notify(error, vim.log.levels.ERROR)
      return
    end
    insert(item)
  end
  if path ~= nil then
    attach(path)
  else
    vim.ui.input({ prompt = "Image file: ", completion = "file" }, attach)
  end
end

local function submit(session_id, content, revision)
  runtime.prompt(session_id, content, function(_, error)
    if error ~= nil then
      util.notify(vim.inspect(error), vim.log.levels.ERROR)
      return
    end
    if state.compose.revision == revision then
      compose.clear(state.compose)
    end
  end)
end

function M.send()
  local content, error = compose.serialize(state.compose)
  if content == nil then
    util.notify(error, vim.log.levels.ERROR)
    return
  end
  if #content == 0 or (#content == 1 and content[1].kind == "text" and content[1].text == "") then
    util.notify("compose buffer is empty", vim.log.levels.WARN)
    return
  end
  local revision = state.compose.revision
  local session_id = runtime.active_session()
  if session_id ~= nil then
    submit(session_id, content, revision)
    return
  end
  runtime.new_session(function(created, create_error)
    if create_error ~= nil then
      util.notify(vim.inspect(create_error), vim.log.levels.ERROR)
      return
    end
    submit(created.session_id, content, revision)
  end)
end

function M.toggle()
  sidebar.toggle()
end

function M.cancel()
  runtime.cancel_active()
end

function M.new_session()
  sessions.new(function(_, error)
    if error ~= nil then
      util.notify(vim.inspect(error), vim.log.levels.ERROR)
    end
  end)
end

function M.close_session()
  sessions.close(nil, function(_, error)
    if error ~= nil then
      util.notify(vim.inspect(error), vim.log.levels.ERROR)
    end
  end)
end

function M.choose_session()
  sessions.choose()
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
local AUTH_POLL_INTERVAL_MS = 1000
local AUTH_POLL_ATTEMPTS = 600

local function authentication_kind(result)
  return result and string.lower(tostring(result.kind or "")) or ""
end

local function poll_authentication(method_id, generation, attempt)
  if generation ~= auth_generation then
    return
  end
  runtime.authenticate(method_id, function(result, error)
    if generation ~= auth_generation then
      return
    end
    if error ~= nil then
      util.notify(vim.inspect(error), vim.log.levels.ERROR)
      return
    end
    local kind = authentication_kind(result)
    if kind == "authenticated" then
      util.notify("Phenix authentication completed", vim.log.levels.INFO)
      return
    end
    if kind ~= "external" then
      util.notify("Phenix returned an unknown authentication state", vim.log.levels.ERROR)
      return
    end
    if attempt >= AUTH_POLL_ATTEMPTS then
      util.notify("Phenix authentication timed out", vim.log.levels.ERROR)
      return
    end
    vim.defer_fn(function()
      poll_authentication(method_id, generation, attempt + 1)
    end, AUTH_POLL_INTERVAL_MS)
  end)
end

local function api_key_authentication_methods()
  local methods = {}
  for _, provider in ipairs(config_api.api_key_providers()) do
    if type(provider) == "table"
      and type(provider.id) == "string"
      and provider.id ~= ""
      and type(provider.env) == "string"
      and provider.env ~= ""
    then
      local description = provider.description
      if description == nil or description == "" then
        description = "Configure through $" .. provider.env
      else
        description = description .. " · $" .. provider.env
      end
      table.insert(methods, {
        id = "frontend.api-key:" .. provider.id,
        name = provider.name or provider.id,
        description = description,
        _phenix_api_key = provider,
      })
    end
  end
  return methods
end

local function use_api_key(provider)
  local selection = provider.selection
  if selection ~= nil then
    runtime.set_preferred_selection(selection)
  end

  if runtime.has_environment(provider.env) then
    if runtime.active_session() ~= nil and selection ~= nil then
      runtime.select(selection, function(_, error)
        if error ~= nil then
          util.notify(vim.inspect(error), vim.log.levels.ERROR)
          return
        end
        util.notify((provider.name or provider.id) .. " selected", vim.log.levels.INFO)
      end)
    else
      util.notify((provider.name or provider.id) .. " is configured through $" .. provider.env, vim.log.levels.INFO)
    end
    return
  end

  vim.ui.input({
    prompt = (provider.name or provider.id) .. ": ",
    secret = true,
  }, function(secret)
    if secret == nil then
      return
    end
    if type(secret) ~= "string" or secret:match("%S") == nil then
      util.notify("API key must not be empty", vim.log.levels.ERROR)
      return
    end
    runtime.reconnect_with_env(provider.env, secret, selection, function(_, error)
      if error ~= nil then
        util.notify(vim.inspect(error), vim.log.levels.ERROR)
        return
      end
      util.notify((provider.name or provider.id) .. " configured", vim.log.levels.INFO)
    end)
  end)
end

function M.authenticate()
  if type(runtime.list_authentication_methods) ~= "function" or type(runtime.authenticate) ~= "function" then
    util.notify("The installed Phenix runtime does not expose application authentication yet", vim.log.levels.WARN)
    return
  end
  runtime.list_authentication_methods(function(result, error)
    if error ~= nil then
      util.notify(vim.inspect(error), vim.log.levels.ERROR)
      return
    end
    local methods = vim.deepcopy(result and result.methods or {})
    vim.list_extend(methods, api_key_authentication_methods())
    if #methods == 0 then
      util.notify("No Phenix authentication methods are available", vim.log.levels.WARN)
      return
    end
    vim.ui.select(methods, {
      prompt = "Phenix authentication",
      format_item = function(method)
        local label = method.name or method.id or "unknown"
        if method.description ~= nil and method.description ~= "" then
          return label .. "  ·  " .. method.description
        end
        return label
      end,
    }, function(method)
      if method == nil then
        return
      end
      if method._phenix_api_key ~= nil then
        use_api_key(method._phenix_api_key)
        return
      end
      auth_generation = auth_generation + 1
      local generation = auth_generation
      runtime.authenticate(method.id, function(auth_result, auth_error)
        if generation ~= auth_generation then
          return
        end
        if auth_error ~= nil then
          util.notify(vim.inspect(auth_error), vim.log.levels.ERROR)
          return
        end
        local kind = authentication_kind(auth_result)
        if kind == "authenticated" then
          util.notify("Phenix authentication completed", vim.log.levels.INFO)
          return
        end
        if kind ~= "external" then
          util.notify("Phenix returned an unknown authentication state", vim.log.levels.ERROR)
          return
        end
        if not open_external_auth(auth_result) then
          util.notify("Phenix authentication did not provide a valid authorization URL", vim.log.levels.ERROR)
          return
        end
        vim.defer_fn(function()
          poll_authentication(method.id, generation, 1)
        end, AUTH_POLL_INTERVAL_MS)
      end)
    end)
  end)
end

function M.choose_selection()
  runtime.list_selections(function(result, error)
    if error ~= nil then
      util.notify(vim.inspect(error), vim.log.levels.ERROR)
      return
    end
    local available = result and result.available or {}
    if #available == 0 then
      util.notify("No Phenix routing selections are available for this session", vim.log.levels.WARN)
      return
    end
    vim.ui.select(available, {
      prompt = "Phenix model / routing",
      format_item = function(item)
        return choice_label(item, result.selected)
      end,
    }, function(item)
      if item == nil then
        return
      end
      runtime.select(item.id, function(_, select_error)
        if select_error ~= nil then
          util.notify(vim.inspect(select_error), vim.log.levels.ERROR)
        end
      end)
    end)
  end)
end

return M
