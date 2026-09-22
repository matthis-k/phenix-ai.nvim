local M = {}

local mime_types = {
  png = "image/png",
  jpg = "image/jpeg",
  jpeg = "image/jpeg",
  gif = "image/gif",
  webp = "image/webp",
}

local extensions = {
  ["image/png"] = "png",
  ["image/jpeg"] = "jpg",
  ["image/gif"] = "gif",
  ["image/webp"] = "webp",
}

function M.from_bytes(name, mime_type, bytes)
  if extensions[mime_type] == nil then
    return nil, "unsupported image MIME type: " .. tostring(mime_type)
  end
  if type(bytes) ~= "string" or bytes == "" then
    return nil, "image payload is empty"
  end
  return {
    kind = "image",
    name = name or ("clipboard." .. extensions[mime_type]),
    mime_type = mime_type,
    bytes = bytes,
  }
end

function M.from_file(path)
  local handle, error = io.open(path, "rb")
  if handle == nil then
    return nil, error
  end
  local bytes = handle:read("*a")
  handle:close()
  local extension = path:match("%.([^.]+)$")
  local mime_type = extension and mime_types[extension:lower()] or nil
  if mime_type == nil then
    return nil, "unsupported image type: " .. path
  end
  local value, decode_error = M.from_bytes(vim.fn.fnamemodify(path, ":t"), mime_type, bytes)
  if value == nil then
    return nil, decode_error
  end
  value.path = vim.fn.fnamemodify(path, ":p")
  return value
end

local function backend()
  local value = vim.ui and vim.ui.img or nil
  if type(value) ~= "table" or type(value.set) ~= "function" or type(value.del) ~= "function" then
    return nil
  end
  return value
end

function M.available()
  return backend() ~= nil
end

function M.preview(image, placement)
  local renderer = backend()
  if renderer == nil then
    return nil
  end
  local ok, id = pcall(renderer.set, image.bytes, placement or {})
  if ok and type(id) == "number" then
    return id
  end
  return nil
end

function M.update(id, placement)
  local renderer = backend()
  if renderer == nil or id == nil then
    return false
  end
  local ok = pcall(renderer.set, id, placement or {})
  return ok
end

function M.close(id)
  local renderer = backend()
  if renderer == nil or id == nil then
    return false
  end
  local ok, found = pcall(renderer.del, id)
  return ok and found ~= false
end

function M.fallback(image)
  return string.format("[image: %s]", image.name)
end

return M