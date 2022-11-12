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
  ---use 'gpanders/editorconfig.nvim'

  -- COLORS!!
  use 'sainnhe/gruvbox-material'

  -- multiple cursors, like in Sublime
  use 'mg979/vim-visual-multi'

  -- icons!
  -- use 'ryanoasis/vim-devicons'

  -- statusline
  use 'ojroques/nvim-hardline'

  -- LSP!!!
  use {
    "williamboman/mason.nvim",
    "williamboman/mason-lspconfig.nvim",
    "neovim/nvim-lspconfig",
  }

  -- debug adapter protocol
  -- https://github.com/mfussenegger/nvim-dap
  use 'mfussenegger/nvim-dap'

  -- linter lsp integration
  -- https://github.com/mfussenegger/nvim-lint
  -- use 'mfussenegger/nvim-lint'

  -- formatter integration
  -- https://github.com/mhartington/formatter.nvim
  use { 'mhartington/formatter.nvim' }

  -- Treesitter!
  use {
    'nvim-treesitter/nvim-treesitter',
    run = function() require('nvim-treesitter.install').update({ with_sync = true }) end,
  }
  use 'nvim-treesitter/nvim-treesitter-context'

  -- smart indentation based on treesitter. ref to experiment later
  -- use({ "yioneko/nvim-yati", tag = "*", requires = "nvim-treesitter/nvim-treesitter" })

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

-- helper function for key bindings
local function bind(op, outer_opts)
  outer_opts = outer_opts or {noremap = true}
  return function(lhs, rhs, opts)
    opts = vim.tbl_extend(
      "force",
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
require('hardline').setup({})
require('nvim-treesitter.configs').setup({
  ensure_installed = {
    'bash',
    'c',
    'cmake',
    'comment',
    'cpp',
    'css',
    'diff',
    'dockerfile',
    'dot',
    'fennel',
    'gdscript',
    'git_rebase',
    'gitattributes',
    'gitignore',
    'go',
    'godot_resource',
    'graphql',
    'hcl',
    'help',
    'html',
    'hocon',
    'http',
    'java',
    'javascript',
    'jsdoc',
    'json',
    'kotlin',
    'lua',
    'make',
    'markdown',
    'markdown_inline',
    'python',
    'regex',
    'scss',
    'sql',
    'swift',
    'toml',
    'typescript',
    'vim',
    'vue',
    'yaml'
  }, -- install all parsers
  indent = { -- EXPERIMENTAL. may need to try nvim-yati
    enable = true
  },
  highlight = {
    -- can configure to disable for specific languages, or function to e.g. not use on a large file
    enable = true
  },
  incremental_selection = { -- maybe look into textregions
    enable = true,
    keymaps = {
      init_selection = "gnn",
      node_incremental = "grn",
      scope_incremental = "grc",
      node_decremental = "grm",
    },
  },
})
-- LSP client manager, auto installer, and auto configuration
require("mason").setup({
  ui = {
    icons = {
      package_installed = "✓",
      package_pending = "➜",
      package_uninstalled = "✗"
    }
  }
})
-- for servers: https://github.com/williamboman/mason-lspconfig.nvim
require("mason-lspconfig").setup({
  ensure_installed = {
    'tsserver', -- typescript
    'stylelint_lsp', -- css, scss, etc.
    'angularls', -- angular
    'jsonls', -- JSON
    'yamlls', -- YAML
    'jdtls', -- java
    'eslint', -- eslint
    --'gopls', -- go
    --'kotlin_language_server', -- kotlin
    'bashls', -- bash / zsh
    --'vuels', -- vue
    --'gdscript', -- godot script (not available currently)
    'jedi_language_server', -- python
    'sumneko_lua', -- lua
  }
})
-- trouble (diagnostics) settings
require('trouble').setup({})

-- Telescope Settings
local builtin = require('telescope.builtin')
nnoremap('<leader>ff', function() builtin.find_files() end)
nnoremap('<leader>faf', function() builtin.find_files({hidden=true}) end)
nnoremap('<leader>fg', function() builtin.live_grep() end)
nnoremap('<leader>fb', function() builtin.buffers() end)
nnoremap('<leader>fh', function() builtin.help_tags() end)

local actions = require('telescope.actions')
local previewers = require('telescope.previewers')
require('telescope').setup{
  defaults = {
    file_previewer = previewers.vim_buffer_cat.new,
    grep_previewer = previewers.vim_buffer_vimgrep.new,
    qflist_previewer = previewers.vim_buffer_qflist.new,
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


-- completion and lsp settings
-- Setup nvim-cmp.
local cmp = require('cmp')

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
    ['<CR>'] = cmp.mapping.confirm({
      behavior = cmp.ConfirmBehavior.Replace,
      select = true
    }),
  --['<Tab>'] = cmp.mapping(function(fallback)
  --  if cmp.visible() then
  --    cmp.select_next_item()
  --  elseif luasnip.expand_or_jumpable() then
  --    luasnip.expand_or_jump()
  --  else
  --    fallback()
  --  end
  --end, { 'i', 's' }),
  --['<S-Tab>'] = cmp.mapping(function(fallback)
  --  if cmp.visible() then
  --    cmp.select_prev_item()
  --  elseif luasnip.jumpable(-1) then
  --    luasnip.jump(-1)
  --  else
  --    fallback()
  --  end
  --end, { 'i', 's' }),
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

-- Diagnostics Configs
-- open diagnostic (error) messages in floating window
nnoremap('<leader>le', function() vim.diagnostic.open_float() end)
-- move to next diagnostic
nnoremap('<leader>ln', function() vim.diagnostic.goto_next() end)
nnoremap('<leader>lp', function() vim.diagnostic.goto_prev() end)

local function config(server_config)
  return vim.tbl_deep_extend("force", {
    capabilities = require('cmp_nvim_lsp').default_capabilities(),
    on_attach = function(_, bufnr) -- client, bufnr
      local bufopts = { buffer=bufnr }
      -- lsp bindings for various awesomeness
      -- jump to definition of symbol
      nnoremap('<leader>ld', function() vim.lsp.buf.definition() end, bufopts)
      -- jump to implementation of symbol
      nnoremap('<leader>li', function() vim.lsp.buf.implementation() end, bufopts)
      -- display signature info (params, etc.) for symbol
      nnoremap('<leader>ls', function() vim.lsp.buf.signature_help() end, bufopts)
      -- list all refs to symbol in QF window
      nnoremap('<leader>lrr', function() vim.lsp.buf.references() end, bufopts)
      -- rename all refs under symbol
      nnoremap('<leader>lrn', function() vim.lsp.buf.rename() end, bufopts)
      nnoremap('<leader>lh', function() vim.lsp.buf.hover() end, bufopts)
      -- select code action at point (need to experiment)
      nnoremap('<leader>lca', function() vim.lsp.buf.code_action() end, bufopts)
    end
  }, server_config or {})
end

require('mason-lspconfig').setup_handlers({
  function (server_name) -- default handler
    require('lspconfig')[server_name].setup(config())
  end,
  -- override specific servers here
  ['bashls'] = function()
    require('lspconfig').bashls.setup(config({
      filetypes = { 'sh', 'zsh' }
    }))
  end,
  ['sumneko_lua'] = function()
    require('lspconfig').sumneko_lua.setup(config({
      settings = {
        Lua = {
          runtime = {
            -- Tell the language server which version of Lua you're using (most likely LuaJIT in the case of Neovim)
            version = 'LuaJIT',
          },
          diagnostics = {
            -- Get the language server to recognize the `vim` global
            globals = {'vim'},
          },
          workspace = {
            -- Make the server aware of Neovim runtime files
            library = vim.api.nvim_get_runtime_file("", true),
          },
          -- Do not send telemetry data containing a randomized but unique identifier
          telemetry = {
            enable = false,
          },
        },
      }
    }))
  end,
})
-- gdscript doesn't have mason support atm
require('lspconfig').gdscript.setup(config())

require('nvim-web-devicons').setup({
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
})


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
