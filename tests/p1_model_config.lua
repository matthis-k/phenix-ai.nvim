-- Standard ACP session/set_config_option is the only model mutation wire.
local backend = require("phenix_client.acp").new({ command = "unused" })
backend.state = "ready"
backend.features = { management = { models = false, model_selection = false } }

local function model_option(selected)
  return { id = "model", category = "model", type = "select",
    currentValue = selected, options = {
      { name = "Runtime One", value = "provider/one" },
      { name = "Runtime Two", value = "provider/two" },
    } }
end

backend:_catalog("s1", { model_option("provider/one") })
assert(backend.features.management.models)
assert(backend.features.management.model_selection)
local sent, selected, failure
backend._request = function(_, method, params, callback)
  sent = { method = method, params = params }
  callback({ configOptions = { model_option("provider/two") } }, nil)
end
backend:call("models.select", { model_id = "provider/two" }, function(v, err)
  selected, failure = v, err
end)
assert(failure == nil, vim.inspect(failure))
assert(selected.selected == "provider/two")
assert(sent.method == "session/set_config_option")
assert(sent.params.sessionId == "s1" and sent.params.configId == "model")
assert(sent.params.value == "provider/two")
assert(backend.catalogs.s1.selected == "provider/two")

-- Never send a forged model to the runtime or report a local optimistic switch.
sent = nil
backend:call("models.select", { model_id = "forged" }, function(v, err)
  assert(v == nil and err.kind == "denied")
end)
assert(sent == nil and backend.catalogs.s1.selected == "provider/two")

backend._request = function(_, _, _, callback)
  callback(nil, { kind = "denied", message = "runtime denied" })
end
backend:call("models.select", { model_id = "provider/one" }, function(v, err)
  assert(v == nil and err.kind == "denied")
end)
assert(backend.catalogs.s1.selected == "provider/two")

backend._request = function(_, _, _, callback)
  callback({ configOptions = { model_option("provider/one") } }, nil)
end
backend:call("models.select", { model_id = "provider/two" }, function(v, err)
  assert(v == nil and err.kind == "protocol")
end)
assert(backend.catalogs.s1.selected == "provider/one",
  "projection follows runtime response, never requested input")
print("ACP model selection rejects forged, denied and unconfirmed changes")
