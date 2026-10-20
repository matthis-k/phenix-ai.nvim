-- N5 editor tool isolation: Phenix's own unsent UI state is not ordinary
-- editor context. Exercising the local handlers does not claim host admission.
local tools = require("phenix_nvim.tools")
local context = require("phenix_nvim.context")
tools.enable_defaults()
local by_id = {}
for _, entry in ipairs(tools._templates()) do by_id[entry.id] = entry.handler end

local normal = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(normal, 0, -1, false, { "ordinary editor content" })
local normal_uri = context.buffer_uri(normal)

-- Normal buftype does not make a Phenix-owned hidden draft public.
local draft = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_name(draft, "phenix://followup/internal-draft")
vim.api.nvim_buf_set_lines(draft, 0, -1, false, { "UNSENT_PRIVATE_FOLLOWUP" })
vim.b[draft].phenix_internal = true
local draft_uri = context.buffer_uri(draft)

-- A non-Phenix prompt/terminal/special buffer is also not an editor file.
local prompt = vim.api.nvim_create_buf(false, true)
vim.bo[prompt].buftype = "nofile"
vim.api.nvim_buf_set_lines(prompt, 0, -1, false, { "UNSENT_PRIVATE_PROMPT" })
local prompt_uri = context.buffer_uri(prompt)

local function denied(id, options)
  local ok = pcall(by_id[id], options)
  assert(not ok, id .. " exposed an internal or special editor buffer")
end

-- Enumeration cannot leak either buffer or expose a URI as a route back in.
local list = by_id["nvim.context.buffers"]()
local found_normal = false
for _, item in ipairs(list) do
  assert(item.uri ~= draft_uri and item.uri ~= prompt_uri,
    "private UI buffer appeared in the public context catalog")
  if item.uri == normal_uri then found_normal = true end
end
assert(found_normal, "ordinary editor file disappeared from context")

denied("nvim.context.buffer", { uri = draft_uri })
denied("nvim.context.buffer", { uri = prompt_uri })
denied("nvim.context.diagnostics", { uri = draft_uri })
denied("nvim.context.diagnostics", { uri = prompt_uri })

-- Implicit current-buffer access must also refuse the same private buffers.
vim.api.nvim_set_current_buf(draft)
denied("nvim.context.buffer", {})
denied("nvim.context.diagnostics", {})
denied("nvim.context.current_location")
denied("nvim.context.selection")
denied("nvim.context.viewport", {})
vim.api.nvim_set_current_buf(prompt)
denied("nvim.context.buffer", {})
denied("nvim.context.current_location")
denied("nvim.context.viewport", {})
vim.api.nvim_set_current_buf(normal)

-- Quickfix diagnostics sometimes hold buffer IDs directly. Never surface
-- private URI/text for a Phenix-owned entry through that independent route.
vim.fn.setqflist({}, "r", { items = {
  { bufnr = draft, lnum = 1, col = 1, text = "UNSENT_PRIVATE_FOLLOWUP" },
  { bufnr = prompt, lnum = 1, col = 1, text = "UNSENT_PRIVATE_PROMPT" },
  { bufnr = normal, lnum = 1, col = 1, text = "ordinary quickfix" },
} })
local quickfix = by_id["nvim.context.quickfix"]({ limit = 20 })
assert(#quickfix == 1 and quickfix[1].text == "ordinary quickfix",
  "private quickfix entry was exposed")

-- The same tools remain useful for a regular editor file.
local snapshot = by_id["nvim.context.buffer"]({ uri = normal_uri })
assert(snapshot.text == "ordinary editor content" and not snapshot.truncated)
local cursor = by_id["nvim.context.current_location"]()
assert(cursor.uri == normal_uri)
local viewport = by_id["nvim.context.viewport"]({ max_bytes = 128 })
assert(viewport.text == "ordinary editor content")
tools.disable_defaults()
print("N5 editor internal buffer isolation passed")
