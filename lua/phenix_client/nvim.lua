-- Neovim picker for the presentation-neutral Phenix Lua SDK.
-- The runtime supplies the complete catalog and authorizes every mutation.
local M = {}

function M.choose_model(client, session_or_callback, callback)
  assert(client and type(client.list_models) == "function")
  local session_id
  if type(session_or_callback) == "function" then
    callback = session_or_callback
  else
    session_id = session_or_callback
  end
  assert(type(callback) == "function")
  client:list_models(session_id, function(catalog, error)
    if error then callback(nil, error); return end
    local options = catalog and catalog.models or {}
    if #options == 0 then
      callback(nil, { kind = "unavailable", message = "Phenix has no selectable models" })
      return
    end
    vim.ui.select(options, {
      prompt = "Phenix model",
      format_item = function(item)
        local marker = item.id == catalog.selected and "✓ " or "  "
        return marker .. (item.name or item.id)
      end,
    }, function(item)
      if not item then
        callback(nil, { kind = "cancelled", message = "Model selection cancelled" })
        return
      end
      if item.id == catalog.selected then
        callback(catalog, nil)
        return
      end
      -- Never update a frontend-owned selection on an optimistic guess.
      -- The caller must refresh from Phenix's returned result or event.
      if session_id == nil then
        callback(nil, { kind = "invalid_input",
          message = "Model selection requires an explicit session" })
        return
      end
      client:set_model(session_id, item.id, callback)
    end)
  end)
end

return M
