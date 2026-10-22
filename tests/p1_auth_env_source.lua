-- End-user API-key source chooser: only the name crosses the editor/runtime
-- boundary. A stored name is not provider authentication.
local actions = require("phenix_nvim.actions")
local runtime = require("phenix_nvim.runtime")
local util = require("phenix_nvim.util")
local auth_ui = require("phenix_nvim.ui.auth")
local saved = {
  list = runtime.list_authentication_methods,
  active = runtime.p1_active,
  bind = runtime.bind_auth_environment,
  authenticate = runtime.authenticate,
  select = auth_ui.select,
  input = vim.ui.input,
  secret = util.input_secret,
  notify = util.notify,
}
local selected, bound, direct, notices, requested_input, mode, source
local function reset()
  selected, bound, direct, notices, requested_input = {}, {}, {}, {}, nil
  mode = "authenticated"
  source = "Read from environment variable"
end
reset()
runtime.p1_active = function() return false end
runtime.list_authentication_methods = function(done)
  done({ methods = {{
    provider_id = "openai", connection_id = "api",
    method_id = "api-key", profile_id = "personal",
    kind = "ApiKey", label = "API key",
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
  selected[#selected + 1] = { items = items, prompt = opts.prompt }
  assert(opts.prompt:find("API key source", 1, true))
  cb(source)
end
vim.ui.input = function(opts, done)
  requested_input = opts.prompt
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
assert(#notices == 1 and notices[1].message:find("authentication completed", 1, true))
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
  elseif key == "active" then runtime.p1_active = value
  elseif key == "bind" then runtime.bind_auth_environment = value
  elseif key == "authenticate" then runtime.authenticate = value
  elseif key == "select" then auth_ui.select = value
  elseif key == "input" then vim.ui.input = value
  elseif key == "secret" then util.input_secret = value
  elseif key == "notify" then util.notify = value end
end
print("Native auth env source name / direct / denied / stored UX tests passed")
