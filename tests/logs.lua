local config = require("phenix_nvim.config")
local logs = require("phenix_nvim.logs")

local root = vim.fn.tempname()
vim.fn.mkdir(root .. "/objects/sha256", "p")

local object = vim.json.encode({
  source = "agent-loop",
  event = "tool_call",
  execution_id = "execution-7",
  callable_id = "workspace.write",
  path = "spec/logging.md",
})
local digest = vim.fn.sha256(object)
local relative = "sha256/" .. digest:sub(1, 2) .. "/" .. digest
vim.fn.mkdir(root .. "/objects/sha256/" .. digest:sub(1, 2), "p")
assert(vim.fn.writefile({ object }, root .. "/objects/" .. relative, "b") == 0)

local reference = {
  digest = "sha256:" .. digest,
  media_type = "application/json",
  bytes = #object,
  locator = {
    backend = "file",
    path = relative,
  },
}

local records = {
  vim.json.encode({
    timestamp_ms = 1000,
    kind = "runtime_trace",
    payload = {
      summary = { source = "agent-loop", event = "tool_call" },
      detail = {
        kind = "inline",
        value = {
          execution_id = "execution-1",
          event = "tool_call",
          callable_id = "workspace.shell",
        },
      },
    },
  }),
  vim.json.encode({
    timestamp_ms = 2000,
    kind = "runtime_trace",
    payload = {
      summary = { source = "agent-loop", event = "tool_call" },
      detail = {
        kind = "inline",
        value = {
          execution_id = "execution-1",
          event = "tool_call",
          callable_id = "workspace.read",
        },
      },
    },
  }),
  vim.json.encode({
    timestamp_ms = 3000,
    kind = "agent_diagnostic",
    payload = {
      summary = {
        event = "model_turn_started",
        execution_id = "execution-1",
        turn = 2,
      },
      detail = {
        kind = "inline",
        value = {
          event = "model_turn_started",
          execution_id = "execution-1",
          turn = 2,
        },
      },
    },
  }),
  vim.json.encode({
    timestamp_ms = 4000,
    kind = "runtime_trace",
    payload = {
      summary = { event = "service_invocation" },
      detail = {
        kind = "inline",
        value = {
          trace = {
            event = "service_invocation",
            service = "phenix.execution@1",
            success = false,
            error = "fixture failure",
          },
        },
      },
    },
  }),
  vim.json.encode({
    timestamp_ms = 5000,
    kind = "runtime_trace",
    payload = {
      summary = {
        event = "tool_invocation_started",
        execution_id = "execution-7",
        callable_id = "workspace.write",
      },
      detail = {
        kind = "reference",
        reference = reference,
      },
    },
  }),
}

assert(vim.fn.writefile(records, root .. "/phenix.log") == 0)
config.setup({
  auto_connect = false,
  log_directory = root,
  log_depth = "reference",
})

local buf = assert(logs.open())
assert(vim.api.nvim_get_current_buf() == buf)
assert(logs.is_log_buffer(buf))
assert(vim.bo[buf].buftype == "nofile")
assert(vim.bo[buf].filetype == "phenixlog")
assert(vim.bo[buf].modifiable == false)
assert(vim.bo[buf].readonly == true)
assert(vim.deep_equal(vim.api.nvim_buf_get_lines(buf, 0, -1, false), records), "inspector must keep raw JSONL in the buffer")

assert(logs.category_at(buf, 1) == "bash")
assert(logs.category_at(buf, 2) == "read")
assert(logs.category_at(buf, 3) == "model")
assert(logs.category_at(buf, 4) == "agent")
assert(logs.failure_at(buf, 4), "failed agent activity must retain its semantic category and failure state")
assert(logs.category_at(buf, 5) == "write", "root semantic metadata must classify referenced diagnostics without loading content")

local marks = vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })
assert(#marks == #records, "each raw record must have one semantic decoration")
assert(marks[1][4].virt_text ~= nil, "semantic view must render virtual text over raw JSONL")

vim.api.nvim_win_set_cursor(0, { 1, 0 })
assert(logs.toggle_details(buf) == true)
marks = vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })
assert(marks[1][4].virt_lines ~= nil, "expanded records must expose structured virtual detail")
assert(logs.toggle_details(buf) == false)

assert(logs.toggle_raw(buf) == true)
marks = vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })
assert(marks[1][4].virt_text == nil, "raw mode must remove the semantic overlay")
assert(logs.toggle_raw(buf) == false)

vim.api.nvim_win_set_cursor(0, { 5, 0 })
assert(logs.follow_reference(buf) == true)
local object_buf = vim.api.nvim_get_current_buf()
assert(object_buf ~= buf)
assert(logs.is_log_buffer(object_buf))
assert(vim.api.nvim_buf_get_name(object_buf):find("sha256:" .. digest, 1, true) ~= nil)
assert(vim.deep_equal(vim.api.nvim_buf_get_lines(object_buf, 0, -1, false), { object }))
assert(logs.category_at(object_buf, 1) == "write")
assert(vim.bo[object_buf].modifiable == false and vim.bo[object_buf].readonly == true)

vim.api.nvim_set_current_buf(buf)
assert(logs.refresh(buf) == true)
assert(vim.deep_equal(vim.api.nvim_buf_get_lines(buf, 0, -1, false), records))

pcall(vim.api.nvim_buf_delete, object_buf, { force = true })
pcall(vim.api.nvim_buf_delete, buf, { force = true })
vim.fn.delete(root, "rf")
