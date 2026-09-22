local frontend = require("phenix_nvim")
frontend.setup({ auto_connect = false })

local sidebar = require("phenix_nvim.sidebar")
local compose = require("phenix_nvim.compose.buffer")
local compose_model = require("phenix_nvim.compose.model")
local state = require("phenix_nvim.state")
local transcript = require("phenix_nvim.transcript.buffer")

local function wait_until(predicate, message)
  assert(vim.wait(1000, predicate, 10), message)
end

-- A partially closed sidebar is invalid state. Closing either pane tears down its sibling
-- so the next open starts from one coherent layout instead of stale window ids.
local first_tab = vim.api.nvim_get_current_tabpage()
sidebar.open()
local transcript_win, compose_win = sidebar.windows()
assert(vim.api.nvim_win_is_valid(transcript_win))
assert(vim.api.nvim_win_is_valid(compose_win))
vim.api.nvim_win_close(compose_win, true)
wait_until(function()
  return not sidebar.is_open()
end, "closing one sidebar pane must reconcile the whole sidebar")
assert(not vim.api.nvim_win_is_valid(transcript_win), "orphaned transcript pane must be closed")

-- Sidebar windows are tab-local. Opening Phenix in another tab must not overwrite the
-- first tab's layout state.
sidebar.open()
local first_transcript, first_compose = sidebar.windows()
vim.cmd("tabnew")
local second_tab = vim.api.nvim_get_current_tabpage()
sidebar.open()
local second_transcript, second_compose = sidebar.windows()
assert(first_transcript ~= second_transcript and first_compose ~= second_compose)
assert(vim.api.nvim_win_is_valid(first_transcript) and vim.api.nvim_win_is_valid(first_compose))

vim.api.nvim_set_current_tabpage(first_tab)
wait_until(function()
  local current_transcript, current_compose = sidebar.windows()
  return current_transcript == first_transcript and current_compose == first_compose
end, "returning to a tab must restore its sidebar layout")
sidebar.close()
assert(not vim.api.nvim_win_is_valid(first_transcript))
assert(not vim.api.nvim_win_is_valid(first_compose))
assert(vim.api.nvim_win_is_valid(second_transcript) and vim.api.nvim_win_is_valid(second_compose))

vim.api.nvim_set_current_tabpage(second_tab)
wait_until(sidebar.is_open, "second tab sidebar must survive changes in another tab")

-- Replacing one of the sidebar buffers also invalidates the layout.
local replacement = vim.api.nvim_create_buf(false, true)
vim.api.nvim_win_set_buf(second_compose, replacement)
wait_until(function()
  return not sidebar.is_open()
end, "replacing a sidebar buffer must reconcile the sidebar")
assert(not vim.api.nvim_win_is_valid(second_transcript), "buffer replacement must not leave an orphan pane")

-- Attachment identity comes from extmarks, not text that merely looks like an attachment
-- marker. Large or pasted text can therefore contain marker-shaped strings safely.
sidebar.open()
local _, input_win = sidebar.windows()
local document = state.compose
compose.clear(document)
local item = compose_model.add(document, {
  kind = "resource",
  source = { uri = "file:///tmp/context.txt" },
  snapshot = "context",
})
assert(compose.insert(document, item, input_win))
local marker = compose.marker(item)
local input_buffer = vim.api.nvim_win_get_buf(input_win)
local first_line = vim.api.nvim_buf_get_lines(input_buffer, 0, 1, false)[1]
vim.api.nvim_buf_set_text(input_buffer, 0, #first_line, 0, #first_line, { " pasted " .. marker })
local serialized = assert(compose.serialize(document))
assert(serialized[1].kind == "resource", "the extmarked marker must serialize as the attachment")
assert(serialized[2].kind == "text", "pasted marker-shaped text must remain ordinary text")
assert(serialized[2].text == " pasted " .. marker)

local paste_mappings = {}
for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(input_buffer, "n")) do
  paste_mappings[mapping.lhs] = true
end
assert(paste_mappings.p and paste_mappings.P, "compose must own normal paste handling buffer-locally")

-- Transcript rendering uses explicit role labels and readable window-local display options.
local transcript_buffer = transcript.ensure()
local current_transcript = select(1, sidebar.windows())
transcript.render_projection({
  order = { "user", "assistant" },
  nodes = {
    user = { id = "user", kind = "message", role = "user", text = "hello" },
    assistant = { id = "assistant", kind = "message", role = "assistant", text = "world" },
  },
})
local lines = vim.api.nvim_buf_get_lines(transcript_buffer, 0, -1, false)
assert(lines[1] == "You")
assert(vim.tbl_contains(lines, "Assistant"))
assert(vim.wo[current_transcript].wrap)
assert(vim.wo[current_transcript].linebreak)
assert(not vim.wo[current_transcript].number)

sidebar.close()
