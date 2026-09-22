local commands = require("phenix_nvim.commands")
local actions = require("phenix_nvim.actions")

vim.cmd.runtime("plugin/phenix.lua")

assert(vim.fn.exists(":Phenix") == 2, "one Phenix command must be registered")
for _, legacy in ipairs({
  "PhenixToggle",
  "PhenixReference",
  "PhenixReferencePick",
  "PhenixReferenceAt",
  "PhenixSend",
  "PhenixCancel",
  "PhenixNew",
  "PhenixClose",
  "PhenixSessions",
  "PhenixAuth",
  "PhenixSelect",
  "PhenixImage",
}) do
  assert(vim.fn.exists(":" .. legacy) == 0, legacy .. " must be folded into :Phenix")
end

local calls = {}
local originals = {}
for _, name in ipairs({
  "toggle",
  "send",
  "cancel",
  "authenticate",
  "choose_selection",
  "reference",
  "reference_range",
  "reference_picker",
  "reference_at",
  "attach_image",
  "new_session",
  "close_session",
  "choose_session",
  "new",
}) do
  originals[name] = actions[name]
  actions[name] = function(...)
    table.insert(calls, { name = name, args = { ... } })
    return true
  end
end

local function execute(...)
  commands.execute({ fargs = { ... } })
end

execute()
execute("send")
execute("reference")
commands.execute({ fargs = { "reference" }, range = 2, line1 = 3, line2 = 5 })
execute("reference", "pick")
execute("reference", "at", "/tmp/a", "b.txt")
execute("image")
execute("image", "clipboard")
execute("image", "/tmp/a", "b.png")
execute("session", "new")
execute("session", "close")
execute("session", "select")
execute("new")
execute("new", "sidebar")
execute("new", "tab")
execute("new", "curr_window")
execute("new", "fullscreen")
execute("auth")
execute("select")
execute("cancel")

local names = {}
for _, call in ipairs(calls) do
  table.insert(names, call.name)
end
assert(vim.deep_equal(names, {
  "toggle",
  "send",
  "reference",
  "reference_range",
  "reference_picker",
  "reference_at",
  "attach_image",
  "attach_image",
  "attach_image",
  "new_session",
  "close_session",
  "choose_session",
  "new",
  "new",
  "new",
  "new",
  "new",
  "authenticate",
  "choose_selection",
  "cancel",
}))
assert(calls[4].args[1] == 3 and calls[4].args[2] == 5)
assert(calls[6].args[1] == "/tmp/a b.txt")
assert(calls[7].args[1] == "clipboard")
assert(calls[8].args[1] == "clipboard")
assert(calls[9].args[1] == "/tmp/a b.png")
assert(calls[13].args[1] == "sidebar")
assert(calls[14].args[1] == "sidebar")
assert(calls[15].args[1] == "tab")
assert(calls[16].args[1] == "curr_window")
assert(calls[17].args[1] == "fullscreen")

local before_invalid = #calls
execute("toggle", "unexpected")
execute("send", "unexpected")
execute("cancel", "unexpected")
execute("auth", "unexpected")
execute("select", "unexpected")
execute("new", "unexpected")
execute("new", "sidebar", "extra")
execute("window", "close")
execute("window", "move", "left")
assert(#calls == before_invalid, "commands with unexpected or removed arguments must not execute mutations")

local roots = commands.complete("", "Phenix ", #"Phenix ")
assert(vim.tbl_contains(roots, "image"))
assert(vim.tbl_contains(roots, "session"))
assert(vim.tbl_contains(roots, "reference"))
assert(vim.tbl_contains(roots, "new"))
assert(not vim.tbl_contains(roots, "window"))

local presentations = commands.complete("", "Phenix new ", #"Phenix new ")
assert(vim.tbl_contains(presentations, "sidebar"))
assert(vim.tbl_contains(presentations, "tab"))
assert(vim.tbl_contains(presentations, "curr_window"))
assert(vim.tbl_contains(presentations, "fullscreen"))

local image_sources = commands.complete("", "Phenix image ", #"Phenix image ")
assert(vim.tbl_contains(image_sources, "clipboard"))
assert(type(image_sources) == "table")

local sessions = commands.complete("", "Phenix session ", #"Phenix session ")
assert(vim.tbl_contains(sessions, "new"))
assert(vim.tbl_contains(sessions, "close"))
assert(vim.tbl_contains(sessions, "select"))

for name, original in pairs(originals) do
  actions[name] = original
end
