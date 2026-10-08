-- Deterministic display contract fixture; no backend or model required.
local doc = require("phenix_nvim.ui.document")
local view = require("phenix_nvim.ui.buffer")
local fixture = {
  version = 1, session_id = "session-a", document_id = "document-a", revision = 1,
  root = { id = "root", kind = "column", children = {
    { id = "label", kind = "label", text = "Status" },
    { id = "badge", kind = "badge", text = "Queued" },
    { id = "progress", kind = "progress", fraction = 0.5, text = "Running" },
    { id = "table", kind = "table", columns = { "Name", "State" },
      rows = { { "build", "passed" } } },
    { id = "row", kind = "row", children = {
      { id = "row-label", kind = "label", text = "Tasks" },
      { id = "row-badge", kind = "badge", text = "3" },
    } },
  } },
}
local buffer = assert(view.present(fixture))
local lines = vim.api.nvim_buf_get_lines(buffer, 0, -1, false)
assert(vim.tbl_contains(lines, "  Running [========--------] 50%"))
assert(vim.tbl_contains(lines, "  build | passed"))
assert(vim.tbl_contains(lines, "  Tasks  [3]"), "row must render children horizontally")
local marks = vim.api.nvim_buf_get_extmarks(
  buffer,
  vim.api.nvim_get_namespaces()["phenix-structured-ui"],
  0,
  -1,
  {}
)
assert(#marks == 2, "badge and progress must receive theme-aware highlights")
assert(view.present(fixture) == buffer, "same revision must be idempotent")
local collision = vim.deepcopy(fixture)
collision.root.children[1].text = "different text at the same revision"
local conflicted, conflict_error = view.present(collision)
assert(conflicted == nil and conflict_error:find("conflicting", 1, true),
  "equal revisions with different content must reject without overwriting")
local same_render = vim.deepcopy(fixture)
same_render.root.children[1].id = "renamed-but-visually-identical"
local structural, structural_error = view.present(same_render)
assert(structural == nil and structural_error:find("conflicting", 1, true),
  "identical rendering must not allow different node identities at the same revision")
local exact_value = vim.deepcopy(fixture)
exact_value.root.children[3].fraction = 0.501
local value_conflict, value_error = view.present(exact_value)
assert(value_conflict == nil and value_error:find("conflicting", 1, true),
  "visually rounded progress must not hide a same-revision state change")
local changed = vim.deepcopy(fixture)
changed.revision = 2
changed.root.children[2].text = "Completed"
assert(view.present(changed) == buffer)
local stale, error = view.present(fixture)
assert(stale == nil and error:find("stale"), "old revisions must not overwrite new ones")

local function reject(mutator)
  local invalid = vim.deepcopy(fixture)
  mutator(invalid)
  local projected = doc.project(invalid)
  assert(projected == nil, "invalid UI document passed validation")
end
reject(function(d) d.root.children[1].id = "badge" end)
reject(function(d) d.root.children[1].kind = "button" end)
reject(function(d) d.root.children[5].children[2].kind = "progress" end)
reject(function(d) d.root.children[1].text = string.char(27) .. "[2J" end)
reject(function(d) d.root.children[3].fraction = 1.5 end)
reject(function(d) d.root.children[4].rows[1] = { "only one cell" } end)
reject(function(d) d.version = 2 end)
reject(function(d) d.root.children[1].text = string.rep("x", 4097) end)
reject(function(d)
  local table_node = d.root.children[4]
  local cols, cells = {}, {}
  for _ = 1, 12 do
    cols[#cols + 1] = "Column"
    cells[#cells + 1] = string.rep("x", 1000)
  end
  table_node.columns = cols
  table_node.rows = { cells }
end)
reject(function(d)
  local rows = {}
  for _ = 1, 100 do
    rows[#rows + 1] = { string.rep("x", 1000), string.rep("y", 1000) }
  end
  d.root.children[4].rows = rows
end)

local other = vim.deepcopy(fixture)
other.session_id = "session-b"
assert(view.present(other) ~= buffer, "sessions must not share buffers")
vim.api.nvim_buf_delete(buffer, { force = true })
local recreated = assert(view.present(changed))
assert(vim.api.nvim_buf_is_valid(recreated), "replayed document must recreate its wiped buffer")
assert(recreated ~= buffer, "recreated buffer must have a new identity")
view.close("session-a", "document-a")
view.close("session-b", "document-a")
print("structured UI display fixture passed")
