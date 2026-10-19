-- Read-only provider catalog via ACP extension. Registration never grants
-- authentication or model entitlement to the Neovim SDK.
local sdk = require("phenix_client")
local transport = require("phenix_client.acp").new({ command = "fake-acp" })
local outgoing
transport.state = "ready"
transport.features = { session_operations = {}, management = {} }
transport.job = 1
transport._write = function(_, frame)
  outgoing = frame
  return true
end
local client = sdk.new(transport)
client:start(function(_, err) assert(not err) end)

local catalog, catalog_error
client:list_providers(function(value, err)
  catalog, catalog_error = value, err
end)
assert(outgoing.method == "_phenix/providers/list")
assert(outgoing.params.scope == "user" and outgoing.params.token == nil)
local first = outgoing.id
transport:_response({
  jsonrpc = "2.0", id = first,
  result = { revision = 7, providers = {
    { id = "openai", label = "OpenAI", connections = {
      { id = "api", label = "OpenAI API", auth_methods = {
        { id = "api-key", label = "API key", kind = "ApiKey" },
      } },
      { id = "chatgpt", label = "ChatGPT", auth_methods = {
        { id = "oauth", label = "OAuth", kind = "OAuthAuthorizationCode" },
      } },
    } },
  } },
})
assert(not catalog_error and catalog.revision == 7)
assert(catalog.providers[1].connections[1].auth_methods[1].kind == "ApiKey")
assert(catalog.providers[1].connections[2].auth_methods[1].kind == "OAuthAuthorizationCode")
assert(not client:capabilities().management.providers,
  "read-only capability probe must not invent authentication readiness")

local absent, unsupported
client:list_providers(function(value, err)
  absent, unsupported = value, err
end)
transport:_response({
  jsonrpc = "2.0", id = outgoing.id,
  error = { code = -32601, message = "Method not found" },
})
assert(absent == nil and unsupported.kind == "unsupported",
  "older Basic hosts must reject optional discovery without fallback")

local malformed, protocol_error
client:list_providers(function(value, err)
  malformed, protocol_error = value, err
end)
transport:_response({
  jsonrpc = "2.0", id = outgoing.id, result = {
    revision = 8, providers = { { label = "missing id", connections = {} } },
  },
})
assert(malformed == nil and protocol_error.kind == "protocol",
  "malformed runtime catalog cannot be promoted to an SDK authority")

-- The editor UI sees provider registrations but must not offer an implicit
-- authentication success or a model selection.
client:close()
package.loaded["phenix_nvim.runtime"] = {
  status = function() return { connection = "ready" } end,
  on_event = function() return function() end end,
  list_providers = function(callback) callback(catalog, nil) end,
}
local util = require("phenix_nvim.util")
local old_select, old_notify = vim.ui.select, util.notify
local picker, rendered
vim.ui.select = function(items, options, callback)
  assert(options.prompt == "Installed Phenix providers (not authenticated)")
  picker = items
  callback(items[1])
end
util.notify = function(message, level)
  rendered = { message = message, level = level }
end
require("phenix_nvim.actions").providers()
vim.ui.select, util.notify = old_select, old_notify
assert(#picker == 1 and picker[1].id == "openai")
assert(rendered.level == vim.log.levels.INFO)
assert(rendered.message:find("registered, not authenticated", 1, true))
assert(rendered.message:find("OpenAI API", 1, true))
assert(rendered.message:find("ChatGPT", 1, true))
print("Read-only ACP provider catalog and Neovim display remain non-authoritative")
