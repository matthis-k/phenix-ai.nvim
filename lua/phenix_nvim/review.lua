local M = {}
local pending_decisions = {}

local function state_kind(review)
  local kind = type(review.state) == "table" and review.state.kind or nil
  return type(kind) == "string" and kind:lower() or nil
end

local function render(review, buffer)
  if not vim.api.nvim_buf_is_valid(buffer) then
    return
  end
  local state = state_kind(review) or "pending"
  local lines = {
    "# Phenix review",
    "",
    "State: " .. state,
  }
  if state == "conflicted" and review.state.message ~= nil then
    table.insert(lines, "Conflict: " .. review.state.message)
  end
  table.insert(lines, "")
  for _, file in ipairs(review.files or {}) do
    table.insert(lines, "## " .. (file.uri or "file"))
    if file.conflict ~= nil then
      table.insert(lines, "Conflict: " .. tostring(file.conflict))
      table.insert(lines, "")
    end
    for _, hunk in ipairs(file.hunks or {}) do
      table.insert(lines, "```diff")
      vim.list_extend(lines, vim.split(hunk.unified_diff or "", "\n", { plain = true }))
      table.insert(lines, "```")
    end
    table.insert(lines, "")
  end
  vim.bo[buffer].modifiable = true
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, lines)
  vim.bo[buffer].modifiable = false
end

local function decide(review, decision, buffer, updated_callback)
  if state_kind(review) ~= "pending" then
    return
  end

  local key = tostring(review.id) .. ":" .. tostring(review.revision)
  if pending_decisions[key] then
    return
  end
  pending_decisions[key] = true

  local settled = false
  local function complete(updated, error)
    if settled then
      return
    end
    settled = true
    pending_decisions[key] = nil

    if error ~= nil then
      vim.notify(vim.inspect(error), vim.log.levels.ERROR, { title = "Phenix" })
      return
    end
    if updated ~= nil then
      render(updated, buffer)
      updated_callback(updated)
      local state = state_kind(updated)
      if state == "conflicted" then
        vim.notify("Phenix review conflicted", vim.log.levels.WARN, { title = "Phenix" })
      elseif state == "accepted" then
        vim.notify("Phenix review accepted", nil, { title = "Phenix" })
      elseif state == "rejected" then
        vim.notify("Phenix review rejected", nil, { title = "Phenix" })
      end
    end
  end

  local runtime = require("phenix_nvim.runtime")
  local ok, error = pcall(runtime.decide_review, review, decision, complete)
  if not ok then
    complete(nil, { message = tostring(error) })
  end
end

function M.open(review)
  if type(review) ~= "table"
    or type(review.id) ~= "string"
    or type(review.revision) ~= "number"
    or type(review.files) ~= "table"
  then
    return nil, "invalid structured review"
  end
  local current = vim.deepcopy(review)
  local buffer = vim.api.nvim_create_buf(false, true)
  vim.bo[buffer].buftype = "nofile"
  vim.bo[buffer].bufhidden = "wipe"
  vim.bo[buffer].swapfile = false
  vim.bo[buffer].filetype = "diff"
  vim.api.nvim_buf_set_name(buffer, "phenix://review/" .. current.id)
  render(current, buffer)
  vim.keymap.set("n", "a", function()
    decide(current, "accept", buffer, function(updated)
      current = updated
    end)
  end, { buffer = buffer, desc = "Accept Phenix review" })
  vim.keymap.set("n", "r", function()
    decide(current, "reject", buffer, function(updated)
      current = updated
    end)
  end, { buffer = buffer, desc = "Reject Phenix review" })
  vim.cmd("tabnew")
  vim.api.nvim_win_set_buf(0, buffer)
  vim.wo[0].winbar = "%#Title# Review %#WinBar#  ·  " .. tostring(state_kind(current) or "pending")
  return buffer
end

return M
