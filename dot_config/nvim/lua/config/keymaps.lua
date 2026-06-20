-- Keymaps are automatically loaded on the VeryLazy event
-- Default keymaps that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/keymaps.lua
-- Add any additional keymaps here
local map = LazyVim.safe_keymap_set

map("n", "<leader>msd", function()
  Snacks.words.disable()
end, { desc = "Disable Snacks Words" })
map("n", "<leader>mse", function()
  Snacks.words.enable()
end, { desc = "Enable Snacks Words" })
