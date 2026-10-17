vim.deprecate = function(name)
  error("deprecated API: " .. name)
end
local buffer = require("phenix_nvim.transcript.buffer")
local tool_view = require("phenix_nvim.transcript.tool_view")
local key = {}
local projection = { order = { "first", "middle", "last" }, nodes = {} }
for _, id in ipairs(projection.order) do
  projection.nodes[id] = { id = id, kind = "message", role = "assistant", text = id }
end
buffer.render_projection(projection, key)
local target = buffer.ensure(key)
local win = vim.api.nvim_get_current_win()
vim.api.nvim_win_set_buf(win, target)
buffer.attach_window(key, win)
buffer.set_follow_tail(true, win, key)
local function check(label)
  local expected = {}
  for _, id in ipairs(projection.order) do
    local node = projection.nodes[id]
    if node.kind == "tool" then
      vim.list_extend(expected, tool_view.lines(node, "compact", vim.api.nvim_win_get_width(win)))
      table.insert(expected, "")
    else
      vim.list_extend(expected, { "Assistant", "" })
      vim.list_extend(expected, vim.split(node.text, "\n", { plain = true }))
      table.insert(expected, "")
    end
  end
  local actual = vim.api.nvim_buf_get_lines(target, 0, -1, false)
  assert(vim.deep_equal(actual, expected), label .. ": transcript corrupted\n" .. vim.inspect(actual))
  assert(vim.api.nvim_win_get_cursor(win)[1] == #actual, label .. ": follow-tail lost")
end
local failures = {}
for _, id in ipairs({ "first", "middle" }) do
  for _, resize in ipairs({ "grow", "shrink" }) do
    for _, reset_id in ipairs(projection.order) do
      projection.nodes[reset_id].text = reset_id
    end
    if resize == "shrink" then projection.nodes[id].text = id .. "\nlong\nbody" end
    buffer.render_projection(projection, key)
    projection.nodes[id].text = resize == "grow" and id .. "\ngrown\nagain" or id
    buffer.render_node(projection.nodes[id], key)
    local ok, err = pcall(function()
      check(id .. " " .. resize)
      -- Updating every other node exposes a misplaced boundary immediately.
      for _, next_id in ipairs(projection.order) do
        if next_id ~= id then
          projection.nodes[next_id].text = projection.nodes[next_id].text .. "!"
          buffer.render_node(projection.nodes[next_id], key)
          check(id .. " " .. resize .. ": " .. next_id .. " subsequent update")
        end
      end
    end)
    if not ok then table.insert(failures, err) end
  end
end
assert(#failures == 0, table.concat(failures, "\n"))
-- Disclosure must still route to the right node after earlier-node resizes.
for _, id in ipairs({ "middle", "last" }) do
  projection.nodes[id] = {
    id = id, kind = "tool", callable_id = id .. ".worker", state = "completed",
    input = "payload-" .. id,
  }
  buffer.render_node(projection.nodes[id], key)
end
buffer.remember_projection(projection, key)
projection.nodes.first.text = "first\nresized\nonce more"
buffer.render_node(projection.nodes.first, key)
check("before disclosure")
buffer.set_follow_tail(false, win, key)
for _, id in ipairs({ "middle", "last" }) do
  local row
  for index, line in ipairs(vim.api.nvim_buf_get_lines(target, 0, -1, false)) do
    if line:find(id .. ".worker", 1, true) then row = index end
  end
  vim.api.nvim_win_set_cursor(win, { assert(row), 0 })
  assert(buffer.set_tool_mode(win, key, "human"), id .. ": wrong disclosure target")
  local text = table.concat(vim.api.nvim_buf_get_lines(target, 0, -1, false), "\n")
  assert(text:find("payload-" .. id, 1, true), id .. ": payload not opened")
  assert(not buffer.is_following_tail(win, key), "disclosure must preserve detached follow-tail")
  assert(buffer.set_tool_mode(win, key, "compact"))
end
buffer.detach_window(win)
print("P1 transcript first/middle grow/shrink and subsequent updates accepted")
