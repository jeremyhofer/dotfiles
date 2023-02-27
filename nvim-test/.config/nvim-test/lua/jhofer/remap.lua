local utils = require("jhofer.utils")

-- exit terminal buffer!
utils.tnoremap('<ESC>', '<C-\\><C-n>')

-- life saving copy to system clipboard remaps
utils.nnoremap('<leader>y', '"+y')
utils.vnoremap('<leader>y', '"+y')
utils.nnoremap('<leader>Y', 'gg"+yG')
utils.nnoremap('<leader>p', '"+p')

-- quick buffer navigation
utils.nnoremap('<leader>a', function() vim.cmd.bp() end)
utils.nnoremap('<leader>d', function() vim.cmd.bn() end)
utils.nnoremap('<leader>x', function() vim.cmd.bd() end)

-- BEGONE FOUL BEAST
utils.nnoremap('<leader>rm', function() vim.api.nvim_call_function('delete', {vim.api.nvim_eval('@%')}) end)

-- yank it and slap it down!
utils.nnoremap('<leader>rwy', 'ciw<C-r>0')

-- quick edit config with \v
utils.nnoremap('<leader>v', function() vim.cmd.e(vim.api.nvim_eval('$MYVIMRC')) end)

-- toggle spell
utils.nnoremap('<leader>sp', function() vim.opt_local.spell = not vim.opt_local.spell:get() end)

-- all about that Sex(plore) ;)
utils.nnoremap('<leader>n', function() vim.cmd.Sexplore() end)

-- close a split
utils.nnoremap('<leader>q', '<C-w>q')

