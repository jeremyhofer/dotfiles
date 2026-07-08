-- Options are automatically loaded before lazy.nvim startup
-- Default options that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/options.lua
-- Add any additional options here
vim.g.snacks_animate = false
-- Declare the nerd font explicitly so icon rendering is intentional + identical across
-- machines (LazyVim otherwise auto-guesses; it read as nil on every box).
vim.g.have_nerd_font = true
-- lua/config/options.lua
-- vim.filetype.add({
--   pattern = {
--     -- Match any file ending in .component.html
--     [".*%.component%.html"] = "htmlangular",
--   },
-- })
