-- Autocmds are automatically loaded on the VeryLazy event
-- Default autocmds that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/autocmds.lua
-- Add any additional autocmds here

-- Keep chezmoi's copy of the lazy lockfile (+ LazyVim extras state) in sync after
-- any plugin operation, so `chezmoi apply` never reverts plugin versions. Fires on
-- the lockfile-mutating lazy.nvim events; no-op on machines without chezmoi.
vim.api.nvim_create_autocmd("User", {
  pattern = { "LazyInstall", "LazyUpdate", "LazySync", "LazyClean", "LazyRestore" },
  callback = function()
    if vim.fn.executable("chezmoi") == 1 then
      vim.fn.jobstart({
        "chezmoi", "re-add",
        vim.fn.expand("~/.config/nvim/lazy-lock.json"),
        vim.fn.expand("~/.config/nvim/lazyvim.json"),
      })
    end
  end,
})
