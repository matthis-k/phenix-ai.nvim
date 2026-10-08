-- Display-only structured documents. Backend action and capability contracts are pending.
local M = {}
local MAX_NODES, MAX_DEPTH, MAX_TEXT, MAX_LINES = 128, 12, 4096, 512
local MAX_LINE_BYTES, MAX_TOTAL_BYTES = 8192, 65536
local leaf = { text = true, label = true, badge = true, progress = true, table = true }
local layout = { row = true, column = true, card = true }

local function valid_text(value, field, optional)
  if value == nil and optional then
    return ""
  end
  if type(value) ~= "string" or #value > MAX_TEXT then
    error(field .. " must be a bounded string")
  end
  if value:find("[%z\1-\8\11\12\14-\31\127]") then
    error(field .. " contains terminal control characters")
  end
  return value
end

local function nonempty(value, field)
  local text = valid_text(value, field)
  if text == "" then
    error(field .. " must not be empty")
  end
  return text
end

local function integer(value)
  return type(value) == "number" and value >= 0 and value == math.floor(value)
end

function M.project(document)
  if type(document) ~= "table" or document.version ~= 1 then
    return nil, "unsupported UI document version"
  end
  local ok, result = pcall(function()
    local session_id = nonempty(document.session_id, "session_id")
    local document_id = nonempty(document.document_id, "document_id")
    if not integer(document.revision) then
      error("revision must be a non-negative integer")
    end
    local ids, lines, styles, count, bytes = {}, {}, {}, 0, 0
    local function add(line, style)
      for index, segment in ipairs(vim.split(line, "\n", { plain = true })) do
        if #lines >= MAX_LINES then
          error("document exceeds line limit")
        end
        if #segment > MAX_LINE_BYTES then
          error("document exceeds line byte limit")
        end
        bytes = bytes + #segment + 1
        if bytes > MAX_TOTAL_BYTES then
          error("document exceeds total byte limit")
        end
        lines[#lines + 1] = segment
        if index == 1 and style ~= nil then
          styles[#styles + 1] = { row = #lines - 1, end_col = #segment, kind = style }
        end
      end
    end
    local function accept_id(node)
      count = count + 1
      if count > MAX_NODES then
        error("document exceeds node limit")
      end
      local id = nonempty(node.id, "node id")
      if ids[id] then
        error("duplicate node id: " .. id)
      end
      ids[id] = true
    end
    local visit
    visit = function(node, depth)
      if type(node) ~= "table" or depth > MAX_DEPTH then
        error("invalid node or maximum nesting exceeded")
      end
      accept_id(node)
      local kind = node.kind
      if not leaf[kind] and not layout[kind] then
        error("unsupported display node: " .. tostring(kind))
      end
      local prefix = string.rep("  ", depth)
      if kind == "text" or kind == "label" then
        add(prefix .. valid_text(node.text, "text"))
      elseif kind == "badge" then
        add(prefix .. "[" .. valid_text(node.text, "badge") .. "]", "badge")
      elseif kind == "progress" then
        local fraction = node.fraction
        if type(fraction) ~= "number" or fraction ~= fraction or fraction < 0 or fraction > 1 then
          error("progress fraction must be within 0..1")
        end
        local filled = math.floor(fraction * 16 + 0.5)
        add(prefix .. valid_text(node.text, "progress label", true) .. " ["
          .. string.rep("=", filled) .. string.rep("-", 16 - filled)
          .. "] " .. tostring(math.floor(fraction * 100 + 0.5)) .. "%", "progress")
      elseif kind == "row" then
        if type(node.children) ~= "table" or #node.children == 0 then
          error("row requires children")
        end
        local cells = {}
        for _, child in ipairs(node.children) do
          if type(child) ~= "table" or (child.kind ~= "text" and child.kind ~= "label" and child.kind ~= "badge") then
            error("row children must be inline text, labels or badges")
          end
          if depth + 1 > MAX_DEPTH then
            error("row exceeds nesting limit")
          end
          accept_id(child)
          local value = valid_text(child.text, "row cell")
          if value:find("\n", 1, true) then
            error("row cells must be single-line")
          end
          cells[#cells + 1] = child.kind == "badge" and ("[" .. value .. "]") or value
        end
        add(prefix .. table.concat(cells, "  "))
      elseif kind == "table" then
        if type(node.columns) ~= "table" or #node.columns == 0 or #node.columns > 12
          or type(node.rows) ~= "table" or #node.rows > 100 then
          error("invalid table dimensions")
        end
        local columns = {}
        for _, item in ipairs(node.columns) do
          columns[#columns + 1] = valid_text(item, "column")
        end
        add(prefix .. table.concat(columns, " | "))
        for _, row in ipairs(node.rows) do
          if type(row) ~= "table" or #row ~= #columns then
            error("table row width mismatch")
          end
          local cells = {}
          for _, cell in ipairs(row) do
            cells[#cells + 1] = valid_text(cell, "cell")
          end
          add(prefix .. table.concat(cells, " | "))
        end
      else
        if kind == "card" then
          add(prefix .. valid_text(node.title, "card title", true))
        end
        if type(node.children) ~= "table" or #node.children == 0 then
          error("layout node requires children")
        end
        for _, child in ipairs(node.children) do
          visit(child, depth + 1)
        end
      end
    end
    visit(document.root, 0)
    return {
      session_id = session_id,
      document_id = document_id,
      revision = document.revision,
      lines = lines,
      styles = styles,
    }
  end)
  if not ok then
    return nil, tostring(result)
  end
  return result
end

return M
