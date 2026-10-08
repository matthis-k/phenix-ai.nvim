-- No frontend capability is advertised here. This viewer accepts local, validated documents.
local document = require("phenix_nvim.ui.document")

local M = {}
local views = {}
local highlights = vim.api.nvim_create_namespace("phenix-structured-ui")

function M.present(value)
  local projection, error = document.project(value)
  if projection == nil then
    return nil, error
  end
  local key = projection.session_id .. "\0" .. projection.document_id
  local view = views[key]
  if view ~= nil and projection.revision < view.revision then
    return nil, "stale UI document revision"
  end
  if view ~= nil and projection.revision == view.revision then
    return view.buffer
  end
  if view == nil or not vim.api.nvim_buf_is_valid(view.buffer) then
    view = {
      buffer = vim.api.nvim_create_buf(false, true),
      revision = -1,
    }
    vim.bo[view.buffer].buftype = "nofile"
    vim.bo[view.buffer].bufhidden = "wipe"
    vim.bo[view.buffer].swapfile = false
    vim.bo[view.buffer].modifiable = false
    views[key] = view
  end
  vim.bo[view.buffer].modifiable = true
  vim.api.nvim_buf_set_lines(view.buffer, 0, -1, false, projection.lines)
  vim.api.nvim_buf_clear_namespace(view.buffer, highlights, 0, -1)
  for _, item in ipairs(projection.styles) do
    vim.api.nvim_buf_set_extmark(view.buffer, highlights, item.row, 0, {
      end_col = item.end_col,
      hl_group = item.kind == "badge" and "DiagnosticInfo" or "DiagnosticHint",
    })
  end
  vim.bo[view.buffer].modifiable = false
  view.revision = projection.revision
  return view.buffer
end

function M.close(session_id, document_id)
  local key = session_id .. "\0" .. document_id
  local view = views[key]
  views[key] = nil
  if view ~= nil and vim.api.nvim_buf_is_valid(view.buffer) then
    vim.api.nvim_buf_delete(view.buffer, { force = true })
  end
end

return M
