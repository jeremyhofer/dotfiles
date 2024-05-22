-- General Settings
vim.opt.background = 'dark'
vim.opt.termguicolors = true
vim.opt.number = true -- line numbers
vim.opt.relativenumber = true -- for relative line numbers for jumping up/down
vim.opt.ruler = true -- show cursor position at bottom of screen
vim.opt.timeoutlen = 1000 -- override 1000 min
vim.opt.ttimeoutlen = 100 -- override 50 min
--vim.opt.completeopt = {'longest','menuone','noinsert','noselect'} -- consider trying default
vim.opt.completeopt = { 'menu', 'menuone', 'noselect' }
vim.opt.updatetime = 50 -- 50ms after no typing to save swp file
vim.opt.signcolumn = 'yes' -- always show sign column
vim.opt.linebreak = true -- break lines at nice characters
vim.opt.confirm = true -- default to ask to save a file
vim.opt.errorbells = false -- bells can piss off!
vim.opt.ignorecase = true -- ignore for searching
vim.opt.smartcase = true -- ignore ignorecase if we have capitals
vim.opt.hlsearch = false -- gets annoying having stuff highlighted
--vim.opt.laststatus = true -- always have status line
vim.opt.smartindent = true
vim.opt.undofile = true
-- use treesitter for folding
vim.opt.foldmethod = 'expr'
vim.opt.foldexpr = 'nvim_treesitter#foldexpr()'
vim.opt.foldlevelstart = 99

-- config for netrw built in file browser - set up similar to Nerdtree
vim.g.netrw_banner = 0
vim.g.netrw_liststyle = 3
vim.g.netrw_altv = 1
vim.g.netrw_winsize = 25
vim.opt.sessionoptions:append("localoptions") -- save local opts to session file
-- below are legacy things. may not need and don't readily use
--set exrc "allow per-project rc's!! - check if I really need/want this
--set splitright " new split to the right of current window - I don't really use splits anymore

-- all below are defaults in nvim, so redundant
--set spelllang=en_us - en by default
--set showcmd " show partial commands - on by default
--set timeout - on by default
--set backupdir=~/.cache " Don't litter swp files everywhere - default in a nvim dir
--set directory=~/.cache " Don't litter swp files everywhere - default in a nvim dir
--set hidden " allow switching to another file in window without saving original file - on by default
--set more " allow long command stuff to be scrolled back in - default on
--set smarttab - default on
