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
        run = ':TSUpdate'
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

require("jhofer")

vim.g.gruvbox_material_background = 'hard'
vim.g.gruvbox_material_better_performance = 1
vim.g.gruvbox_material_foreground = 'original'
vim.cmd.colorscheme 'gruvbox-material'
-- use treesitter for folding
vim.opt.foldmethod = 'expr'
vim.opt.foldexpr = 'nvim_treesitter#foldexpr()'

local utils = require("jhofer.utils")

-- hardline status line
require('hardline').setup()
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
    'lua_ls', -- lua
  }
})
-- trouble (diagnostics) settings
require('trouble').setup()

-- Telescope Settings
local builtin = require('telescope.builtin')
utils.nnoremap('<leader>ff', function() builtin.find_files() end)
utils.nnoremap('<leader>faf', function() builtin.find_files({hidden=true}) end)
utils.nnoremap('<leader>fg', function() builtin.live_grep() end)
utils.nnoremap('<leader>fb', function() builtin.buffers() end)
utils.nnoremap('<leader>fh', function() builtin.help_tags() end)

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

local function config(server_config)
  return vim.tbl_deep_extend("force", {
    capabilities = require('cmp_nvim_lsp').default_capabilities(),
    on_attach = function(_, bufnr) -- client, bufnr
      local bufopts = { buffer=bufnr }
      -- lsp bindings for various awesomeness
      -- jump to definition of symbol
      utils.nnoremap('<leader>ld', function() vim.lsp.buf.definition() end, bufopts)
      -- jump to implementation of symbol
      utils.nnoremap('<leader>li', function() vim.lsp.buf.implementation() end, bufopts)
      -- display signature info (params, etc.) for symbol
      utils.nnoremap('<leader>ls', function() vim.lsp.buf.signature_help() end, bufopts)
      -- list all refs to symbol in QF window
      utils.nnoremap('<leader>lrr', function() vim.lsp.buf.references() end, bufopts)
      -- rename all refs under symbol
      utils.nnoremap('<leader>lrn', function() vim.lsp.buf.rename() end, bufopts)
      utils.nnoremap('<leader>lh', function() vim.lsp.buf.hover() end, bufopts)
      -- select code action at point (need to experiment)
      utils.nnoremap('<leader>lca', function() vim.lsp.buf.code_action() end, bufopts)
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
  ['lua_ls'] = function()
    require('lspconfig').lua_ls.setup(config({
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
