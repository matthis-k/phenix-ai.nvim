-- P1 ChatGPT OAuth installed product: native ACP provider, not mocked Lua.
-- OAuth completion is deliberately not simulated by this smoke: the browser
-- callback must carry a real signed identity and granted plan permission.
local bin = assert(vim.env.PHENIX_P1_CHATGPT_BIN, "ChatGPT ACP executable missing")
local backend = require("phenix_client.acp").new({ command = bin })
local client = require("phenix_client").new(backend)
local function await(invoke, name, rejected)
  local done, result, failure = false, nil, nil
  invoke(function(value, err)
    assert(not done, name .. " callback occurred twice")
    done, result, failure = true, value, err
  end)
  assert(vim.wait(30000, function() return done end, 10), name .. " timed out")
  if rejected then
    assert(failure ~= nil, name .. " unexpectedly succeeded")
    return
  end
  assert(failure == nil, name .. ": " .. vim.inspect(failure))
  assert(result ~= nil, name .. " returned no value")
  return result
end
await(function(cb) client:start(cb) end, "ACP initialize")
local page = await(function(cb) client:list_providers(cb) end, "provider list")
local method
for _, provider in ipairs(page.providers or {}) do
  if provider.id == "openai" then
    for _, connection in ipairs(provider.connections or {}) do
      if connection.id == "chatgpt" then
        for _, entry in ipairs(connection.auth_methods or {}) do
          if entry.kind == "OAuthAuthorizationCode" then method = entry end
        end
      end
    end
  end
end
assert(method and method.id == "chatgpt-sign-in", "ChatGPT OAuth is not installed")
local before = await(function(cb)
  client:get_provider_auth_status("openai", "chatgpt", cb)
end, "initial status")
for _, profile in ipairs(before.profiles or {}) do
  assert(profile.status ~= "Authenticated", "missing OAuth tokens must never count as login")
end
local challenge = await(function(cb)
  client:begin_provider_auth("openai", "chatgpt", method.id, cb)
end, "begin OAuth")
local browser = assert(challenge.OpenBrowser, "expected browser challenge")
assert(type(browser.attempt_id) == "string" and browser.attempt_id ~= "")
assert(type(browser.url) == "string"
  and browser.url:find("https://auth.openai.com/", 1, true) == 1)
assert(browser.url:find("code_challenge", 1, true))
assert(browser.url:find("state=", 1, true))
assert(browser.url:find("nonce=", 1, true))
assert(not browser.url:find("id_token_hint=", 1, true),
  "first-time authorization must not expose a stored ID token")
local pending = await(function(cb)
  client:poll_provider_auth("openai", "chatgpt", browser.attempt_id, cb)
end, "pending OAuth")
assert(pending == "Pending", "OAuth cannot complete without a verified callback")
local cancelled = await(function(cb)
  client:cancel_provider_auth("openai", "chatgpt", browser.attempt_id, cb)
end, "cancel OAuth")
assert(cancelled == "Cancelled")
await(function(cb)
  client:poll_provider_auth("openai", "chatgpt", browser.attempt_id, cb)
end, "reuse cancelled OAuth challenge", true)
client:close()
print("Native packaged ChatGPT OAuth begin/poll/cancel verified")
