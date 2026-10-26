-- Neovim picker for the presentation-neutral Phenix Lua SDK.
-- The runtime supplies the complete catalog and authorizes every mutation.
local M = {}

-- The standalone SDK defaults to vim.ui.select. An embedding editor may
-- supply its own compatible selector without changing model authority.
function M.choose_model(client, session_or_callback, callback, select_ui)
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
      local reason_labels = {
        no_authorized_account_resolver = "no authorized credential resolver was installed",
        account_not_authenticated = "the selected account is not authenticated",
        catalog_unavailable = "provider model discovery is unavailable or denied",
        catalog_empty = "the provider returned no selectable models",
        model_admission_denied = "models did not pass execution and credential admission",
      }
      local details = {}
      for _, reason in ipairs(catalog.denials or {}) do
        local label = reason_labels[reason.code]
        if label then
          details[#details + 1] = (reason.provider_id or "Provider")
            .. "/" .. (reason.connection_id or "?") .. ": " .. label
        end
      end
      local diagnostic = #details > 0 and table.concat(details, "; ")
        or "No authorized provider models are currently selectable"
      callback(nil, { kind = "unavailable", message = diagnostic })
      return
    end
    (select_ui or vim.ui.select)(options, {
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
      -- No session ID means a connection-level default selection;
      -- existing sessions use the same runtime-authoritative picker.
      client:set_model(session_id, item.id, callback)
    end)
  end)
end

return M
