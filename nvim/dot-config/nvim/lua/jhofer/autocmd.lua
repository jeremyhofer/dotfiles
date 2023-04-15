-- set width to 80 for markdown
vim.api.nvim_create_autocmd({'BufRead', 'BufNewFile'}, {
  pattern = '*.md',
  callback = function () vim.opt_local.textwidth = 80 end
})

-- override filetype for specific files
vim.api.nvim_create_autocmd({'BufRead', 'BufNewFile'}, {
  pattern = 'Snakefile',
  callback = function () vim.opt_local.filetype = 'python' end
})

vim.api.nvim_create_autocmd({'BufRead', 'BufNewFile'}, {
  pattern = '.envrc',
  callback = function () vim.opt_local.filetype = 'sh' end
})

vim.api.nvim_create_autocmd({'BufRead', 'BufNewFile'}, {
  pattern = '.mdx',
  callback = function () vim.opt_local.filetype = 'markdown' end
})

vim.api.nvim_create_autocmd({'BufRead', 'BufNewFile'}, {
  pattern = { 'zshrc', 'zprofile' },
  callback = function () vim.opt_local.filetype = 'zsh' end
})

-- toggle relative numbers on insert mode enter/exit
local numbertoggle_id = vim.api.nvim_create_augroup('numbertoggle', {})
vim.api.nvim_create_autocmd({'BufEnter', 'FocusGained', 'InsertLeave'}, {
  group = numbertoggle_id,
  pattern = "*",
  callback = function() vim.opt.relativenumber = true end
})
vim.api.nvim_create_autocmd({'BufLeave', 'FocusLost', 'InsertEnter'}, {
  group = numbertoggle_id,
  pattern = "*",
  callback = function() vim.opt.relativenumber = false end
})
