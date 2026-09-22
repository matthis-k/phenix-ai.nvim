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

local first_tab = vim.api.nvim_get_current_tabpage()
local editor_win = vim.api.nvim_get_current_win()
sidebar.open()
local transcript_win, compose_win, host_win = sidebar.windows()
assert(vim.api.nvim_win_is_valid(host_win))
assert(vim.api.nvim_win_is_valid(transcript_win))
assert(vim.api.nvim_win_is_valid(compose_win))

-- One real split reserves the sidebar. Transcript and compose are floats anchored to it.
local expected_width = math.max(20, math.floor(vim.o.columns * 0.4))
assert(
  math.abs(vim.api.nvim_win_get_width(host_win) - expected_width) <= 1,
  "default sidebar host width must track forty percent of the editor"
)
local transcript_config = vim.api.nvim_win_get_config(transcript_win)
local compose_config = vim.api.nvim_win_get_config(compose_win)
assert(transcript_config.relative == "win" and transcript_config.win == host_win)
assert(compose_config.relative == "win" and compose_config.win == host_win)
assert(transcript_config.width == vim.api.nvim_win_get_width(host_win))
assert(compose_config.width == vim.api.nvim_win_get_width(host_win))

-- The reservation split is implementation state, not a user-selectable third pane.
assert(vim.w[host_win].phenix_sidebar_host == true)
assert(vim.w[host_win].phenix_window_selectable == false)
assert(sidebar.is_host(host_win))
assert(not sidebar.is_selectable(host_win))
assert(sidebar.is_selectable(transcript_win) and sidebar.is_selectable(compose_win))

vim.api.nvim_set_current_win(host_win)
wait_until(function()
  return vim.api.nvim_get_current_win() == compose_win
end, "selecting the host must redirect to the active sidebar child")

vim.api.nvim_set_current_win(transcript_win)
vim.api.nvim_set_current_win(host_win)
wait_until(function()
  return vim.api.nvim_get_current_win() == transcript_win
end, "host selection must preserve the last selected sidebar child")

vim.api.nvim_set_current_win(editor_win)
vim.cmd("wincmd w")
wait_until(function()
  return vim.api.nvim_get_current_win() ~= host_win
end, "native window cycling must never leave focus on the sidebar host")

-- The prompt is scratch state. :quit must never ask to save it; closing it discards
-- the buffer and the host recreates a fresh prompt view.
local old_compose = compose_win
local old_compose_buffer = vim.api.nvim_win_get_buf(compose_win)
assert(vim.bo[old_compose_buffer].bufhidden == "wipe")
vim.api.nvim_buf_set_lines(old_compose_buffer, 0, -1, false, { "discard me" })
assert(vim.bo[old_compose_buffer].modified)
local scratch = compose_model.add(state.compose, {
  kind = "resource",
  source = { uri = "file:///tmp/discard.txt" },
  snapshot = "discard",
})
assert(compose.insert(state.compose, scratch, compose_win))
local quit_ok, quit_error = pcall(vim.api.nvim_win_call, compose_win, function()
  vim.cmd("quit")
end)
assert(quit_ok, "closing a modified prompt must not ask to save: " .. tostring(quit_error))
wait_until(function()
  local _, repaired = sidebar.windows()
  return repaired ~= nil and repaired ~= old_compose and vim.api.nvim_win_is_valid(repaired)
end, "closing the compose float must recreate it while the host survives")
assert(not vim.api.nvim_buf_is_valid(old_compose_buffer), "closed prompt buffer must be discarded")
assert(next(state.compose.items) == nil, "discarding the prompt must discard its attachments")
transcript_win, compose_win, host_win = sidebar.windows()
assert(sidebar.is_open())
assert(vim.api.nvim_win_is_valid(host_win))
local fresh_compose_buffer = vim.api.nvim_win_get_buf(compose_win)
assert(fresh_compose_buffer ~= old_compose_buffer)
assert(vim.deep_equal(vim.api.nvim_buf_get_lines(fresh_compose_buffer, 0, -1, false), { "" }))

-- Child windows are derived state. Mutating one must repair it from the host.

local replacement = vim.api.nvim_create_buf(false, true)
local old_transcript = transcript_win
vim.api.nvim_win_set_buf(transcript_win, replacement)
wait_until(function()
  local repaired = select(1, sidebar.windows())
  return repaired ~= nil
    and repaired ~= old_transcript
    and vim.api.nvim_win_is_valid(repaired)
    and vim.api.nvim_win_get_buf(repaired) == transcript.ensure()
end, "replacing a child float buffer must restore the owned transcript view")

-- The host owns lifecycle. Closing it tears down both floating children.
transcript_win, compose_win, host_win = sidebar.windows()
vim.api.nvim_win_close(host_win, true)
wait_until(function()
  return not sidebar.is_open()
end, "closing the sidebar host must close the whole Phenix view")
assert(not vim.api.nvim_win_is_valid(transcript_win))
assert(not vim.api.nvim_win_is_valid(compose_win))

-- Hosts and their child floats are tab-local.
sidebar.open()
local first_transcript, first_compose, first_host = sidebar.windows()
vim.cmd("tabnew")
local second_tab = vim.api.nvim_get_current_tabpage()
sidebar.open()
local second_transcript, second_compose, second_host = sidebar.windows()
assert(first_host ~= second_host)
assert(first_transcript ~= second_transcript and first_compose ~= second_compose)
assert(vim.api.nvim_win_is_valid(first_host))
assert(vim.api.nvim_win_is_valid(first_transcript) and vim.api.nvim_win_is_valid(first_compose))

vim.api.nvim_set_current_tabpage(first_tab)
wait_until(function()
  local current_transcript, current_compose, current_host = sidebar.windows()
  return current_host == first_host
    and current_transcript == first_transcript
    and current_compose == first_compose
end, "returning to a tab must restore its anchored sidebar view")
sidebar.close()
assert(not vim.api.nvim_win_is_valid(first_host))
assert(not vim.api.nvim_win_is_valid(first_transcript))
assert(not vim.api.nvim_win_is_valid(first_compose))
assert(vim.api.nvim_win_is_valid(second_host))
assert(vim.api.nvim_win_is_valid(second_transcript) and vim.api.nvim_win_is_valid(second_compose))

vim.api.nvim_set_current_tabpage(second_tab)
wait_until(sidebar.is_open, "second tab sidebar must survive changes in another tab")

-- Attachment identity comes from extmarks, not text that merely looks like an attachment
-- marker. Large or pasted text can therefore contain marker-shaped strings safely.
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
