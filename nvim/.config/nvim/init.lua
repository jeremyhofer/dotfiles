local ensure_packer = function()
  local fn = vim.fn
  local install_path = fn.stdpath('data')..'/site/pack/packer/start/packer.nvim'
  if fn.empty(fn.glob(install_path)) > 0 then
    fn.system({'git', 'clone', '--depth', '1', 'https://github.com/wbthomason/packer.nvim', install_path})
    vim.cmd [[packadd packer.nvim]]
    return true
  end
  return false
end

local packer_bootstrap = ensure_packer()

-- return this when moved to module
require('packer').startup(function(use)
  use 'wbthomason/packer.nvim'
  -- My plugins here
  use 'gpanders/editorconfig.nvim'

  -- COLORS!!
  use 'sainnhe/gruvbox-material'

  -- multiple cursors, like in Sublime
  use 'mg979/vim-visual-multi'

  -- icons!
  -- use 'ryanoasis/vim-devicons'

  -- statusline
  use 'ojroques/nvim-hardline'

  -- LSP!!!
  use 'neovim/nvim-lspconfig'

  -- Treesitter!
  use {
    'nvim-treesitter/nvim-treesitter',
    run = function() require('nvim-treesitter.install').update({ with_sync = true }) end,
  }

  -- Telescope!
  --use 'nvim-lua/popup.nvim'
  use {
    'nvim-telescope/telescope.nvim',
    branch = '0.1.x',
    requires = { {'nvim-lua/plenary.nvim'} }
  }

  -- HARPOOOON
  -- use 'ThePrimeagen/harpoon'

  -- Fugitive!
  --use 'tpope/vim-fugitive'
  --use 'junegunn/gv.vim'

  -- diagnostics, the nice way
  use 'kyazdani42/nvim-web-devicons'
  use 'folke/trouble.nvim'

  -- COMPLETION!
  use 'hrsh7th/cmp-nvim-lsp'
  use 'hrsh7th/cmp-buffer'
  use 'hrsh7th/nvim-cmp'

  -- For vsnip user.
  --use 'hrsh7th/cmp-vsnip'
  --use 'hrsh7th/vim-vsnip'

  -- For luasnip user.
  use 'L3MON4D3/LuaSnip'
  use 'saadparwaiz1/cmp_luasnip'

  -- For ultisnips user.
  -- use 'SirVer/ultisnips'
  -- use 'quangnguyen30192/cmp-nvim-ultisnips'

  -- kotlin, because it's a special summer child
  use 'udalov/kotlin-vim'

  -- mermaid syntax
  use 'mracos/mermaid.vim'

  -- Automatically set up your configuration after cloning packer.nvim
  -- Put this at the end after all plugins
  if packer_bootstrap then
    require('packer').sync()
  end
end)

-- General Settings
vim.opt.background = 'dark'
vim.g.gruvbox_material_background = 'hard'
vim.g.gruvbox_material_better_performance = 1
vim.g.gruvbox_material_foreground = 'original'
vim.cmd.colorscheme('gruvbox-material')

vim.opt.termguicolors = true
vim.opt.number = true -- line numbers
vim.opt.relativenumber = true -- for relative line numbers for jumping up/down
vim.opt.ruler = true -- show cursor position at bottom of screen
vim.opt.timeoutlen = 1000 -- override 1000 min
vim.opt.ttimeoutlen = 100 -- override 50 min
vim.opt.completeopt = {'longest','menuone','noinsert','noselect'} -- consider trying default
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
-- below are legacy things. may not need and don't readily use
--set exrc "allow per-project rc's!! - check if I really need/want this
--set splitright " new split to the right of current window - I don't really use splits anymore
--set foldmethod=syntax fold by syntax
--set foldlevelstart=99 " don't fold unless I want to

-- all below are defaults in nvim, so redundant
--set spelllang=en_us - en by default
--set showcmd " show partial commands - on by default
--set timeout - on by default
--set backupdir=~/.cache " Don't litter swp files everywhere - default in a nvim dir
--set directory=~/.cache " Don't litter swp files everywhere - default in a nvim dir
--set hidden " allow switching to another file in window without saving original file - on by default
--set more " allow long command stuff to be scrolled back in - default on
--set smarttab - default on

-- helper function for key bindings
local function bind(op, outer_opts)
    outer_opts = outer_opts or {noremap = true}
    return function(lhs, rhs, opts)
        opts = vim.tbl_extend("force",
            outer_opts,
            opts or {}
        )
        vim.keymap.set(op, lhs, rhs, opts)
    end
end

local nnoremap = bind('n')
local vnoremap = bind('v')
local tnoremap = bind('t')

-- exit terminal buffer!
tnoremap('<ESC>', '<C-\\><C-n>')

-- life saving copy to system clipboard remaps
nnoremap('<leader>y', '"+y')
vnoremap('<leader>y', '"+y')
nnoremap('<leader>Y', 'gg"+yG')
nnoremap('<leader>p', '"+p')

-- quick buffer navigation
nnoremap('<leader>a', function() vim.cmd.bp() end)
nnoremap('<leader>d', function() vim.cmd.bn() end)
nnoremap('<leader>x', function() vim.cmd.bd() end)

-- BEGONE FOUL BEAST
nnoremap('<leader>rm', function() vim.api.nvim_call_function('delete', {vim.api.nvim_eval('@%')}) end)
--nnoremap('<leader>rm', ':call delete(@%)<cr>')

-- yank it and slap it down!
nnoremap('<leader>rwy', 'ciw<C-r>0')

-- quick edit config with \v
nnoremap('<Leader>v', function() vim.cmd.e(vim.api.nvim_eval('$MYVIMRC')) end)

-- toggle spell
nnoremap('<leader>sp', function() vim.opt_local.spell = not vim.opt_local.spell:get() end)

-- all about that Sex(plore) ;)
nnoremap('<Leader>n', function() vim.cmd.Sexplore() end)

-- close a split
nnoremap('<leader>q', '<C-w>q')

-- hardline status line
require('hardline').setup {}
-- treesitter settings
require'nvim-treesitter.configs'.setup { highlight = { enable = true } }

-- telescope settings
local actions = require('telescope.actions')
require('telescope').setup{
  defaults = {
    file_previewer = require'telescope.previewers'.vim_buffer_cat.new,
    grep_previewer = require'telescope.previewers'.vim_buffer_vimgrep.new,
    qflist_previewer = require'telescope.previewers'.vim_buffer_qflist.new,
    mappings = {
      i = {
        ["<C-w>"] = actions.send_selected_to_qflist,
        ["<C-q>"] = actions.send_to_qflist,
      },
      n = {
        ["<C-w>"] = actions.send_selected_to_qflist,
        ["<C-q>"] = actions.send_to_qflist,
      },
    }
  }
}

-- LSP clients
-- tsserver: typescript
-- vuels: Vue
-- jdtls: Java (eclipse)
-- jedi: python
-- yamlls: YAML
-- jsonls: JSON
-- stylelint: css, scss, etc. files

-- trouble settings
require('trouble').setup{}

-- completion and lsp settings
  -- Setup nvim-cmp.
  local cmp = require'cmp'

  cmp.setup({
    snippet = {
      expand = function(args)
        -- For `vsnip` user.
        -- vim.fn["vsnip#anonymous"](args.body)

        -- For `luasnip` user.
        require('luasnip').lsp_expand(args.body)

        -- For `ultisnips` user.
        -- vim.fn["UltiSnips#Anon"](args.body)
      end,
    },
    mapping = cmp.mapping.preset.insert({
      ['<C-d>'] = cmp.mapping.scroll_docs(-4),
      ['<C-f>'] = cmp.mapping.scroll_docs(4),
      ['<C-Space>'] = cmp.mapping.complete(),
      ['<C-e>'] = cmp.mapping.close(),
      ['<CR>'] = cmp.mapping.confirm({ select = true }),
    }),
    sources = {
      { name = 'nvim_lsp' },

      -- For vsnip user.
      -- { name = 'vsnip' },

      -- For luasnip user.
      { name = 'luasnip' },

      -- For ultisnips user.
      -- { name = 'ultisnips' },

      { name = 'buffer' },
    }
  })

  --[[
  -- Setup lspconfig.
  require('lspconfig')[%YOUR_LSP_SERVER%].setup {
      capabilities = require('cmp_nvim_lsp').default_capabilities()
  }-- Setup nvim-cmp.
      ]]
  -- local cmp = require'cmp'

  local function config(_config)
    return vim.tbl_deep_extend("force", {
      capabilities = require('cmp_nvim_lsp').default_capabilities()
    }, _config or {})
  end

  local lspconfig = require('lspconfig')
  lspconfig.stylelint_lsp.setup(config())
  lspconfig.angularls.setup(config())
  lspconfig.jsonls.setup(config())
  lspconfig.yamlls.setup(config())
  lspconfig.jedi_language_server.setup(config({
    cmd={os.getenv("HOME")..'/.local/bin/jedi-language-server'}
  }))
  lspconfig.tsserver.setup(config())
  lspconfig.eslint.setup(config())
  lspconfig.gopls.setup(config())
  lspconfig.kotlin_language_server.setup(config())
  lspconfig.bashls.setup(config({
    filetypes = { "sh", "zsh" }
  }))
  -- lspconfig.vuels.setup(config())
  -- lspconfig.jdtls.setup(config({
  --   cmd={'jdt-language-server'};
  -- }))
  lspconfig.java_language_server.setup(config({
    cmd={''} -- replace w/ path to command
  }))
  lspconfig.gdscript.setup(config())

require'nvim-web-devicons'.setup {
 -- your personnal icons can go here (to override)
 -- you can specify color or cterm_color instead of specifying both of them
 -- DevIcon will be appended to `name`
--  override = {
--   zsh = {
--     icon = "",
--     color = "#428850",
--     cterm_color = "65",
--     name = "Zsh"
--   }
--  };
 -- globally enable default icons (default to false)
 -- will get overriden by `get_icons` option
 default = true;
}

-- use treesitter for folding
vim.opt.foldmethod = 'expr'
vim.opt.foldexpr = 'nvim_treesitter#foldexpr()'

-- Telescope Bindings
local builtin = require('telescope.builtin')
nnoremap('<leader>ff', function()
  builtin.find_files()
end)
nnoremap('<leader>faf', function()
  builtin.find_files({hidden=true})
end)
nnoremap('<leader>fg', function()
  builtin.live_grep()
end)
nnoremap('<leader>fb', function()
  builtin.buffers()
end)
nnoremap('<leader>fh', function()
  builting.help_tags()
end)

-- lsp bindings for various awesomeness
-- jump to definition of symbol
nnoremap('<leader>ld', function()
  vim.lsp.buf.definition()
end)
-- jump to implementation of symbol
nnoremap('<leader>li', function()
  vim.lsp.buf.implementation()
end)
-- display signature info (params, etc.) for symbol
nnoremap('<leader>ls', function()
  vim.lsp.buf.signature_help()
end)
-- list all refs to symbol in QF window
nnoremap('<leader>lrr', function()
  vim.lsp.buf.references()
end)
-- rename all refs under symbol
nnoremap('<leader>lrn', function()
  vim.lsp.buf.rename()
end)

-- below was commented out
--nnoremap <leader>lh :lua vim.lsp.buf.hover()<CR>

-- select code action at point (need to experiment)
nnoremap('<leader>lca', function()
  vim.lsp.buf.code_action()
end)
-- open diagnostic (error) messages in floating window
nnoremap('<leader>le', function()
  vim.diagnostic.open_float();
end)
-- move to next diagnostic
nnoremap('<leader>ln', function()
  vim.lsp.diagnostic.goto_next()
end)

-- config for netrw built in file browser - set up similar to Nerdtree
vim.g.netrw_banner = 0
vim.g.netrw_liststyle = 3
vim.g.netrw_altv = 1
vim.g.netrw_winsize = 25

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
