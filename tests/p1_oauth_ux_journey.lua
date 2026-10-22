-- Headless end-user auth command journey over the existing runtime API.
-- Deliberately no forged credentials or simulated OIDC success: the runtime
-- mock represents the trusted boundary and the UI must not infer login
-- merely from opening a browser. Live provider verification is a separate
-- installed-product gate.
local actions = require("phenix_nvim.actions")
local runtime = require("phenix_nvim.runtime")
local util = require("phenix_nvim.util")
local original = {
  methods = runtime.list_authentication_methods,
  authenticate = runtime.authenticate,
  poll = runtime.poll_authentication,
  active = runtime.p1_active,
  open = vim.ui.open,
  select = vim.ui.select,
  secret = util.input_secret,
  input = vim.ui.input,
  notify = util.notify,
  defer = vim.defer_fn,
}
local method = {
  provider_id = "openai", provider_name = "OpenAI",
  connection_id = "chatgpt", connection_name = "ChatGPT",
  method_id = "oauth", kind = "OAuthAuthorizationCode",
  label = "Continue with ChatGPT",
}
local authorize = "https://auth.openai.com/api/accounts/authorize?state=a"
local second = "https://auth.openai.com/api/accounts/authorize?state=b"
local notices, opened, tasks, polls, begins
local stage
local function reset()
  notices, opened, tasks, polls, begins = {}, {}, {}, 0, 0
  stage = "success"
end
reset()
runtime.p1_active = function() return true end
runtime.list_authentication_methods = function(done)
  done({ methods = { vim.deepcopy(method) } }, nil)
end
runtime.authenticate = function(identity, secret, done)
  begins = begins + 1
  assert(identity.provider_id == "openai" and identity.connection_id == "chatgpt"
    and identity.method_id == "oauth"
    and identity.kind == "OAuthAuthorizationCode")
  assert(secret == nil, "OAuth access/refresh tokens must never go through Lua")
  done({ kind = "external", url = authorize, attempt_id = "a1",
    provider_id = identity.provider_id, connection_id = identity.connection_id,
    method_id = identity.method_id }, nil)
end
runtime.poll_authentication = function(identity, attempt, done)
  polls = polls + 1
  assert(identity.attempt_id == "a1" and attempt == "a1")
  assert(identity.provider_id == "openai" and identity.connection_id == "chatgpt")
  if stage == "success" then
    if polls == 1 then
      done({ kind = "pending" }, nil)
    elseif polls == 2 then
      done({ kind = "awaiting_input", url = authorize, attempt_id = "a1" }, nil)
    elseif polls == 3 then
      done({ kind = "awaiting_input", url = second, attempt_id = "a1" }, nil)
    else
      done({ kind = "authenticated", verified = true,
        profile_id = "verified-account" }, nil)
    end
  elseif stage == "unsafe" then
    done({ kind = "awaiting_input", url = "file:///tmp/unsafe",
      attempt_id = "a1" }, nil)
  else
    done({ kind = "expired" }, nil)
  end
end
util.notify = function(message, level)
  notices[#notices + 1] = { message = tostring(message), level = level }
end
util.input_secret = function()
  error("OAuth UX must never ask Neovim for a secret")
end
vim.ui.input = function()
  error("OAuth UX must not request a credential profile")
end
vim.ui.select = function()
  error("one actionable account method must skip redundant pickers")
end
vim.ui.open = function(url)
  opened[#opened + 1] = url
  return true
end
vim.defer_fn = function(fn, milliseconds)
  assert(milliseconds == 1000, "OAuth poll must be bounded")
  tasks[#tasks + 1] = fn
end
local function drive()
  assert(#tasks > 0, "OAuth state did not schedule another poll")
  local fn = table.remove(tasks, 1)
  fn()
end
local function completed_notice()
  for _, item in ipairs(notices) do
    if item.level == vim.log.levels.INFO
      and item.message:find("authentication completed", 1, true)
    then
      return true
    end
  end
  return false
end

-- Full visible happy path: :Phenix auth -> browser -> pending -> repeat
-- challenge -> rotated challenge -> verified provider completion.
actions.authenticate()
assert(begins == 1 and #opened == 1 and opened[1] == authorize)
assert(not completed_notice(),
  "opening the browser is not provider authentication")
drive()
assert(polls == 1 and #opened == 1 and not completed_notice())
drive()
assert(polls == 2 and #opened == 1,
  "same ongoing OAuth challenge must not reopen the browser")
drive()
assert(polls == 3 and #opened == 2 and opened[2] == second,
  "a reissued challenge must use the new validated browser URI")
assert(not completed_notice())
drive()
assert(polls == 4 and begins == 1 and completed_notice(),
  "provider completed state must finish exactly one OAuth attempt")
assert(#tasks == 0, "completed OAuth must not keep polling")

-- Untrusted plugin data never reaches OS handlers, and cannot create
-- a false logged-in state.
reset()
stage = "unsafe"
actions.authenticate()
assert(#opened == 1)
drive()
assert(#opened == 1, "unsafe challenge reached the browser")
assert(not completed_notice())
assert(#tasks == 0, "unsafe challenge must terminate polling")
local refused = false
for _, item in ipairs(notices) do
  if item.message:find("unsafe authorization URL", 1, true) then
    refused = true
  end
end
assert(refused, "the user must receive an actionable unsafe-URL error")

-- Expired provider-owned attempts must never count as authentication.
reset()
stage = "expired"
actions.authenticate()
drive()
assert(not completed_notice() and #tasks == 0)
assert(#opened == 1 and begins == 1)

for name, value in pairs(original) do
  if name == "methods" then runtime.list_authentication_methods = value
  elseif name == "authenticate" then runtime.authenticate = value
  elseif name == "poll" then runtime.poll_authentication = value
  elseif name == "active" then runtime.p1_active = value
  elseif name == "open" then vim.ui.open = value
  elseif name == "select" then vim.ui.select = value
  elseif name == "secret" then util.input_secret = value
  elseif name == "input" then vim.ui.input = value
  elseif name == "notify" then util.notify = value
  elseif name == "defer" then vim.defer_fn = value end
end
print("Full headless Neovim OAuth onboarding/denial UX journey accepted")
