if vim.g.loaded_phenix_nvim == 1 then
  return
end
vim.g.loaded_phenix_nvim = 1

vim.api.nvim_create_user_command("Phenix", function(options)
  require("phenix_nvim.commands").execute(options)
end, {
  nargs = "*",
  range = true,
  complete = function(arglead, cmdline, cursorpos)
    return require("phenix_nvim.commands").complete(arglead, cmdline, cursorpos)
  end,
})
