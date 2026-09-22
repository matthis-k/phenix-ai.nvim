local image = require("phenix_nvim.image")

local M = {}

local mime_types = {
  { mime = "image/png", extension = "png" },
  { mime = "image/jpeg", extension = "jpg" },
  { mime = "image/webp", extension = "webp" },
  { mime = "image/gif", extension = "gif" },
}

local function executable(name)
  return vim.fn.executable(name) == 1
end

local function run(args)
  if type(vim.system) ~= "function" then
    return nil
  end
  local ok, result = pcall(function()
    return vim.system(args, { text = false }):wait(2000)
  end)
  if not ok or type(result) ~= "table" or result.code ~= 0 then
    return nil
  end
  return result.stdout
end

local function offered_type(listing)
  if type(listing) ~= "string" then
    return nil
  end
  for _, item in ipairs(mime_types) do
    if listing:find(item.mime, 1, true) ~= nil then
      return item
    end
  end
  return nil
end

local function wayland_image()
  if not executable("wl-paste") then
    return nil
  end
  local selected = offered_type(run({ "wl-paste", "--list-types" }))
  if selected == nil then
    return nil
  end
  local bytes = run({ "wl-paste", "--no-newline", "--type", selected.mime })
  if bytes == nil or bytes == "" then
    return nil
  end
  return image.from_bytes("clipboard." .. selected.extension, selected.mime, bytes)
end

local function x11_image()
  if not executable("xclip") then
    return nil
  end
  local selected = offered_type(run({ "xclip", "-selection", "clipboard", "-t", "TARGETS", "-o" }))
  if selected == nil then
    return nil
  end
  local bytes = run({ "xclip", "-selection", "clipboard", "-t", selected.mime, "-o" })
  if bytes == nil or bytes == "" then
    return nil
  end
  return image.from_bytes("clipboard." .. selected.extension, selected.mime, bytes)
end

function M.image()
  if vim.env.WAYLAND_DISPLAY ~= nil and vim.env.WAYLAND_DISPLAY ~= "" then
    local value = wayland_image()
    if value ~= nil then
      return value
    end
  end
  return x11_image()
end

function M.write_temp_image(value)
  if type(value) ~= "table" or value.kind ~= "image" or type(value.bytes) ~= "string" or value.bytes == "" then
    return nil, "clipboard does not contain a supported image"
  end
  local extension = tostring(value.name or ""):match("%.([%w]+)$") or "png"
  local path = vim.fn.tempname() .. "." .. extension
  local handle, open_error = io.open(path, "wb")
  if handle == nil then
    return nil, open_error
  end
  local ok, write_error = pcall(handle.write, handle, value.bytes)
  handle:close()
  if not ok then
    os.remove(path)
    return nil, tostring(write_error)
  end
  return path
end

function M.temp_image_file()
  local value = M.image()
  if value == nil then
    return nil, "clipboard does not contain a supported image"
  end
  return M.write_temp_image(value)
end

function M.register_uses_system_clipboard(register)
  if register == "+" or register == "*" then
    return true
  end
  if register ~= nil and register ~= '"' then
    return false
  end
  local clipboard = vim.opt.clipboard:get()
  return vim.tbl_contains(clipboard, "unnamedplus") or vim.tbl_contains(clipboard, "unnamed")
end

return M
