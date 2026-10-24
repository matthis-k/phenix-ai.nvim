-- End-user API-key source chooser: only the name crosses the editor/runtime
-- boundary. A stored name is not provider authentication.
local actions = require("phenix_nvim.actions")
local runtime = require("phenix_nvim.runtime")
local util = require("phenix_nvim.util")
local auth_ui = require("phenix_nvim.ui.auth")
local saved = {
  list = runtime.list_authentication_methods,
  providers = runtime.list_providers,
  active = runtime.p1_active,
  bind = runtime.bind_auth_environment,
  authenticate = runtime.authenticate,
  select = auth_ui.select,
  input = vim.ui.input,
  secret = util.input_secret,
  notify = util.notify,
}
local selected, bound, direct, notices, requested_input, requested_default, mode, source
local methods = {{
  provider_id = "openai", connection_id = "api",
  method_id = "api-key", profile_id = "personal",
  kind = "ApiKey", label = "API key",
}}
local function reset()
  selected, bound, direct, notices, requested_input, requested_default = {}, {}, {}, {}, nil, nil
  mode = "authenticated"
  source = "Read from environment variable"
end
reset()
runtime.p1_active = function() return false end
runtime.list_authentication_methods = function(done)
  done({ methods = methods }, nil)
end
runtime.list_providers = function(done)
  local method = methods[1]
  done({ revision = 1, providers = {{
    id = method.provider_id, label = method.provider_id,
    connections = { { id = method.connection_id } },
  }} }, nil)
end
runtime.bind_auth_environment = function(identity, name, cb)
  bound[#bound + 1] = { identity = vim.deepcopy(identity), name = name }
  cb({ kind = mode, verified = mode == "authenticated" }, nil)
end
runtime.authenticate = function(identity, secret, cb)
  direct[#direct + 1] = { identity = vim.deepcopy(identity), secret = secret }
  cb({ kind = "authenticated", verified = true }, nil)
end
auth_ui.select = function(items, opts, cb)
  if opts.prompt == "Phenix provider (declared, not authenticated)" then
    assert(#items == 1 and items[1].id == methods[1].provider_id)
    cb(items[1])
    return
  end
  selected[#selected + 1] = { items = items, prompt = opts.prompt }
  assert(opts.prompt:find("API key source", 1, true))
  cb(source)
end
vim.ui.input = function(opts, done)
  requested_input = opts.prompt
  requested_default = opts.default
  done("OPENAI_CUSTOM_KEY")
end
util.input_secret = function() error("Environment source must not ask for a key") end
util.notify = function(message, level)
  notices[#notices + 1] = { message = tostring(message), level = level }
end

actions.authenticate()
assert(#bound == 1 and #direct == 0)
assert(bound[1].name == "OPENAI_CUSTOM_KEY")
assert(bound[1].identity.provider_id == "openai"
  and bound[1].identity.connection_id == "api"
  and bound[1].identity.profile_id == "personal")
assert(requested_input == "Environment variable name: ")
assert(requested_default == "", "unknown API-key providers must not default to OPENAI_API_KEY")
assert(#notices == 1 and notices[1].message:find("authentication completed", 1, true))
reset()
methods = {{
  provider_id = "anthropic", connection_id = "api",
  method_id = "api-key", profile_id = "personal",
  kind = "ApiKey", label = "API key",
  environment_variable = "ANTHROPIC_API_KEY",
}}
actions.authenticate()
assert(#bound == 1 and bound[1].identity.provider_id == "anthropic")
assert(requested_default == "ANTHROPIC_API_KEY",
  "authentication methods can provide their own environment hints")
methods[1].environment_variable = "bad/name"
reset()
actions.authenticate()
assert(requested_default == "", "invalid provider hint must not populate input")
methods = {{
  provider_id = "openai", connection_id = "api",
  method_id = "api-key", profile_id = "personal",
  kind = "ApiKey", label = "API key",
}}
reset()
mode = "stored"
actions.authenticate()
assert(#bound == 1 and #notices == 1)
assert(notices[1].message:find("not yet verified", 1, true))
reset()
vim.ui.input = function(_, done) done("bad/name") end
actions.authenticate()
assert(#bound == 0 and #notices == 1
  and notices[1].level == vim.log.levels.ERROR)
reset()
source = nil
actions.authenticate()
assert(#bound == 0 and #direct == 0)
reset()
source = "Enter API key"
util.input_secret = function(_, done) done("fixture-direct-key", nil) end
actions.authenticate()
assert(#direct == 1 and direct[1].secret == "fixture-direct-key" and #bound == 0)

for key, value in pairs(saved) do
  if key == "list" then runtime.list_authentication_methods = value
  elseif key == "providers" then runtime.list_providers = value
  elseif key == "active" then runtime.p1_active = value
  elseif key == "bind" then runtime.bind_auth_environment = value
  elseif key == "authenticate" then runtime.authenticate = value
  elseif key == "select" then auth_ui.select = value
  elseif key == "input" then vim.ui.input = value
  elseif key == "secret" then util.input_secret = value
  elseif key == "notify" then util.notify = value end
end
print("Native auth env source name / direct / denied / stored UX tests passed")
