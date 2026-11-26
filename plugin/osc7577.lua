if vim.g.loaded_osc7577_nvim then
  return
end
vim.g.loaded_osc7577_nvim = true

require("osc7577")._bootstrap()
