-- UI reads only runtime-provided model choices, then sends selection to Phenix.
local picker = require("phenix_client.nvim")
local sdk = require("phenix_client")
local selected, selected_options, requested, notices
local backend = {
  start = function(_, cb)
    cb({ session_operations = {},
      management = { models = true, model_selection = true } })
  end,
  call = function(_, op, args, cb)
    if op == "models.list" then
      assert(args.session_id == "selected-session", "picker must query the targeted session")
      cb({ selected = "provider/one", models = {
        { id = "provider/one", name = "Runtime One" },
        { id = "provider/two", name = "Runtime Two" },
      } })
    elseif op == "models.select" then
      assert(args.session_id == "selected-session",
        "model mutation must target the same session as the catalog")
      requested = args.model_id
      cb({ selected = args.model_id })
    else
      error("unexpected operation " .. op)
    end
  end,
  subscribe = function() return function() end end,
  close = function() end,
}
local client = sdk.new(backend)
client:start()
local original = vim.ui.select
vim.ui.select = function(items, options, callback)
  selected_options = items
  assert(options.format_item(items[1]):find("Runtime One", 1, true))
  callback(items[2])
end
picker.choose_model(client, "selected-session", function(value, err)
  assert(not err)
  selected = value
end)
assert(#selected_options == 2, "picker must render runtime catalog")
assert(selected.selected == "provider/two" and requested == "provider/two")

-- A rejection must propagate to the UI without claiming an optimistic change.
backend.call = function(_, op, args, cb)
  if op == "models.list" then
    assert(args.session_id == "selected-session")
    cb({ selected = "provider/one", models = {
      { id = "provider/one", name = "Runtime One" },
      { id = "provider/two", name = "Runtime Two" },
    } })
  else
    cb(nil, { kind = "denied", message = "not authorized" })
  end
end
picker.choose_model(client, "selected-session", function(value, err)
  assert(value == nil and err.kind == "denied")
  notices = err
end)
assert(notices and notices.kind == "denied")
-- No selection if Neovim cancels the picker.
vim.ui.select = function(_, _, callback) callback(nil) end
local previous = requested
picker.choose_model(client, "selected-session", function(value, err)
  assert(value == nil and err.kind == "cancelled")
end)
assert(requested == previous)
vim.ui.select = original
client:close()
print("P1 model picker uses runtime catalog and verified mutations")
