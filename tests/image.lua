local image = require("phenix_nvim.image")

local original = vim.ui.img
local calls = {}
vim.ui.img = {
  set = function(value, opts)
    table.insert(calls, { kind = "set", value = value, opts = vim.deepcopy(opts) })
    if type(value) == "number" then
      return value
    end
    return 41
  end,
  get = function(_id)
    return nil
  end,
  del = function(id)
    table.insert(calls, { kind = "del", id = id })
    return true
  end,
}

local from_bytes = assert(image.from_bytes("clipboard.png", "image/png", "clipboard-bytes"))
assert(from_bytes.name == "clipboard.png")
assert(from_bytes.mime_type == "image/png")
assert(from_bytes.bytes == "clipboard-bytes")
assert(from_bytes.path == nil)
local unsupported, unsupported_error = image.from_bytes("clipboard.bmp", "image/bmp", "bytes")
assert(unsupported == nil and unsupported_error ~= nil)

local clipboard = require("phenix_nvim.clipboard")
local temp_image = assert(clipboard.write_temp_image(from_bytes))
local temp_handle = assert(io.open(temp_image, "rb"))
assert(temp_handle:read("*a") == "clipboard-bytes")
temp_handle:close()
os.remove(temp_image)

local attachment = {
  kind = "image",
  name = "snapshot.png",
  path = "/path/is/not/read/again.png",
  mime_type = "image/png",
  bytes = "immutable-snapshot",
}

assert(image.available())
local id = assert(image.preview(attachment, { row = 2, col = 3 }))
assert(id == 41)
assert(calls[1].kind == "set")
assert(calls[1].value == attachment.bytes, "preview must use immutable attachment bytes")
assert(calls[1].opts.row == 2 and calls[1].opts.col == 3)
assert(image.update(id, { row = 5, col = 7 }))
assert(calls[2].kind == "set" and calls[2].value == id)
assert(image.close(id))
assert(calls[3].kind == "del" and calls[3].id == id)
assert(attachment.bytes == "immutable-snapshot", "renderer lifecycle must not mutate attachment bytes")

local model = require("phenix_nvim.compose.model")
local compose = require("phenix_nvim.compose.buffer")
local document = model.new()
local target = compose.ensure(document)
local win = vim.api.nvim_get_current_win()
vim.api.nvim_win_set_buf(win, target)
compose.attach_window(document, win)

local stored = model.add(document, attachment)
local before_insert = #calls
compose.insert(document, stored, win)
assert(#calls > before_insert, "image marker insertion must create a preview when a renderer exists")
assert(calls[before_insert + 1].value == attachment.bytes)
local before_detach = #calls
compose.detach_window(win)
assert(#calls == before_detach + 1 and calls[#calls].kind == "del", "view teardown must close previews")

compose.attach_window(document, win)
assert(calls[#calls].kind == "set", "reopening the compose view must restore image previews")
local before_marker_delete = #calls
vim.api.nvim_buf_set_lines(target, 0, -1, false, { "" })
compose.refresh_previews(document, win)
assert(
  #calls > before_marker_delete and calls[#calls].kind == "del",
  "deleting an image marker must close its preview"
)

compose.clear(document)
local second = model.add(document, attachment)
compose.insert(document, second, win)
local before_wipe = #calls
vim.api.nvim_buf_delete(target, { force = true })
assert(#calls > before_wipe and calls[#calls].kind == "del", "buffer teardown must close image previews")
assert(second.bytes == "immutable-snapshot", "preview cleanup must not mutate the attachment snapshot")

vim.ui.img = original