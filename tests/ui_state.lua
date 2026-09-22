local frontend = require("phenix_nvim")
frontend.setup({ auto_connect = false })

local actions = require("phenix_nvim.actions")
local clipboard = require("phenix_nvim.clipboard")
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
local initial_compose_buffer = vim.fn.bufnr("phenix://compose")
assert(initial_compose_buffer > 0 and vim.api.nvim_buf_is_valid(initial_compose_buffer))
assert(not vim.bo[initial_compose_buffer].buflisted, "compose buffer must stay out of the normal buffer list")
assert(vim.bo[initial_compose_buffer].bufhidden == "hide")
assert(vim.b[initial_compose_buffer].phenix_internal == true)
assert(vim.b[initial_compose_buffer].phenix_role == "compose")
assert(vim.fn.bufwinid(initial_compose_buffer) == -1, "compose buffer should start hidden")

sidebar.open()
local transcript_win, compose_win, host_win = sidebar.windows()
assert(vim.api.nvim_win_get_buf(compose_win) == initial_compose_buffer)
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

-- Replacing a child buffer is repaired from the host instead of letting the two
-- sidebar roles collapse into each other. The hidden compose buffer keeps its draft.
transcript_win, compose_win, host_win = sidebar.windows()
local preserved_compose_buffer = vim.api.nvim_win_get_buf(compose_win)
vim.api.nvim_buf_set_lines(preserved_compose_buffer, 0, -1, false, { "draft survives repair" })
vim.bo[preserved_compose_buffer].modified = false
local old_compose_view = compose_win
vim.api.nvim_win_set_buf(compose_win, transcript.ensure())
wait_until(function()
  local repaired_transcript, repaired_compose = sidebar.windows()
  return repaired_compose ~= nil
    and repaired_compose ~= old_compose_view
    and vim.api.nvim_win_get_buf(repaired_compose) == preserved_compose_buffer
    and vim.api.nvim_win_get_buf(repaired_transcript) == transcript.ensure()
end, "compose/transcript buffer collision must be repaired")
transcript_win, compose_win, host_win = sidebar.windows()
assert(vim.api.nvim_buf_get_lines(preserved_compose_buffer, 0, -1, false)[1] == "draft survives repair")
assert(vim.w[transcript_win].phenix_sidebar_role == "transcript")
assert(vim.w[compose_win].phenix_sidebar_role == "compose")

local old_transcript_view = transcript_win
vim.api.nvim_win_set_buf(transcript_win, preserved_compose_buffer)
wait_until(function()
  local repaired_transcript, repaired_compose = sidebar.windows()
  return repaired_transcript ~= nil
    and repaired_transcript ~= old_transcript_view
    and vim.api.nvim_win_get_buf(repaired_transcript) == transcript.ensure()
    and vim.api.nvim_win_get_buf(repaired_compose) == preserved_compose_buffer
end, "transcript/compose buffer collision must be repaired")

-- Closing a child view is a view operation: it must never ask to save and must
-- preserve the unsent draft and attachment identity while the host repairs the view.
local old_compose = compose_win
local old_compose_buffer = vim.api.nvim_win_get_buf(compose_win)
assert(vim.bo[old_compose_buffer].bufhidden == "hide")
vim.api.nvim_buf_set_lines(old_compose_buffer, 0, -1, false, { "draft survives close" })
vim.bo[old_compose_buffer].modified = true
assert(vim.bo[old_compose_buffer].modified)
local scratch = compose_model.add(state.compose, {
  kind = "resource",
  source = { uri = "file:///tmp/preserved.txt" },
  snapshot = "preserved",
})
assert(compose.insert(state.compose, scratch, compose_win))
local preserved_lines = vim.api.nvim_buf_get_lines(old_compose_buffer, 0, -1, false)
local quit_ok, quit_error = pcall(vim.api.nvim_win_call, compose_win, function()
  vim.cmd("quit")
end)
assert(quit_ok, "closing a modified prompt must not ask to save: " .. tostring(quit_error))
wait_until(function()
  local _, repaired = sidebar.windows()
  return repaired ~= nil and repaired ~= old_compose and vim.api.nvim_win_is_valid(repaired)
end, "closing the compose float must recreate its view while the host survives")
assert(vim.api.nvim_buf_is_valid(old_compose_buffer), "closing the compose view must preserve its draft buffer")
assert(compose_model.get(state.compose, scratch.id) ~= nil, "closing the compose view must preserve attachments")
transcript_win, compose_win, host_win = sidebar.windows()
assert(sidebar.is_open())
assert(vim.api.nvim_win_is_valid(host_win))
assert(vim.api.nvim_win_get_buf(compose_win) == old_compose_buffer)
assert(vim.deep_equal(
  vim.api.nvim_buf_get_lines(old_compose_buffer, 0, -1, false),
  preserved_lines
), "repaired compose view must preserve the exact unsent draft")

-- Toggling the whole sidebar is also presentation-only. It must not destroy input state.
sidebar.close()

-- Even an explicit external wipe cannot leave Phenix without canonical compose state.
local wiped_compose = compose.ensure(state.compose)
assert(wiped_compose == initial_compose_buffer)
vim.api.nvim_buf_delete(wiped_compose, { force = true })
wait_until(function()
  local replacement = vim.fn.bufnr("phenix://compose")
  return replacement > 0
    and replacement ~= wiped_compose
    and vim.api.nvim_buf_is_valid(replacement)
end, "forced compose wipe must recreate the hidden canonical buffer")
local replacement_compose = vim.fn.bufnr("phenix://compose")
assert(not vim.bo[replacement_compose].buflisted)
assert(vim.bo[replacement_compose].bufhidden == "hide")
assert(vim.b[replacement_compose].phenix_internal == true)
assert(vim.b[replacement_compose].phenix_role == "compose")
assert(vim.fn.bufwinid(replacement_compose) == -1)
assert(next(state.compose.items) == nil, "forced wipe must leave compose state valid and empty")
assert(not sidebar.is_open())
assert(vim.api.nvim_buf_is_valid(old_compose_buffer))
assert(old_compose_buffer == initial_compose_buffer)
assert(vim.fn.bufwinid(old_compose_buffer) == -1, "closed sidebar must leave compose buffer hidden")
assert(compose_model.get(state.compose, scratch.id) ~= nil)
assert(vim.deep_equal(vim.api.nvim_buf_get_lines(old_compose_buffer, 0, -1, false), preserved_lines))
sidebar.open()
transcript_win, compose_win, host_win = sidebar.windows()
assert(vim.api.nvim_win_get_buf(compose_win) == old_compose_buffer)
assert(vim.deep_equal(vim.api.nvim_buf_get_lines(old_compose_buffer, 0, -1, false), preserved_lines))
compose.clear(state.compose)

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
assert(vim.api.nvim_buf_is_valid(initial_compose_buffer), "host teardown must not own compose-buffer lifetime")
assert(vim.fn.bufwinid(initial_compose_buffer) == -1)

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

-- Clipboard image attachment uses the same file path as :Phenix image and must never
-- swap transcript/compose buffers while focusing the input view.
compose.clear(document)
local clipboard_path = vim.fn.tempname() .. ".png"
assert(vim.fn.writefile({ "fake-png" }, clipboard_path, "b") == 0)
local original_temp_image_file = clipboard.temp_image_file
clipboard.temp_image_file = function()
  return clipboard_path
end
local before_transcript, before_compose = sidebar.windows()
local image_item = assert(actions.attach_image("clipboard"))
clipboard.temp_image_file = original_temp_image_file
assert(image_item.kind == "image")
assert(vim.fn.filereadable(clipboard_path) == 0, "clipboard temporary image must be removed after snapshotting")
local after_transcript, after_compose = sidebar.windows()
assert(vim.api.nvim_win_get_buf(after_transcript) == transcript.ensure())
assert(vim.api.nvim_win_get_buf(after_compose) == compose.ensure(document))
assert(vim.w[after_transcript].phenix_sidebar_role == "transcript")
assert(vim.w[after_compose].phenix_sidebar_role == "compose")
assert(before_transcript == after_transcript or not vim.api.nvim_win_is_valid(before_transcript))
assert(before_compose == after_compose or not vim.api.nvim_win_is_valid(before_compose))

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

-- Even an explicit transcript buffer wipe cannot turn the compose view into a
-- transcript or leave the transcript blank: the canonical projection is restored.
local old_transcript_buffer = transcript_buffer
vim.api.nvim_buf_delete(old_transcript_buffer, { force = true })
wait_until(function()
  local repaired_transcript, repaired_compose = sidebar.windows()
  if repaired_transcript == nil or repaired_compose == nil then
    return false
  end
  local repaired_buffer = vim.api.nvim_win_get_buf(repaired_transcript)
  if repaired_buffer == old_transcript_buffer or not vim.api.nvim_buf_is_valid(repaired_buffer) then
    return false
  end
  local repaired_lines = vim.api.nvim_buf_get_lines(repaired_buffer, 0, -1, false)
  return repaired_lines[1] == "You"
    and vim.tbl_contains(repaired_lines, "Assistant")
    and vim.api.nvim_win_get_buf(repaired_compose) ~= repaired_buffer
end, "wiping the transcript buffer must rebuild the transcript projection")

sidebar.close()
