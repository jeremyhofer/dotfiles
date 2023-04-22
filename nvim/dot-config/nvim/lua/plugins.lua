return {
  -- COLORS!!
  {
    'sainnhe/gruvbox-material',
    lazy = false, --false as this is main color theme
    priority = 1000, --top priority
    config = function ()
      -- load colorscheme
      vim.g.gruvbox_material_background = 'hard'
      vim.g.gruvbox_material_better_performance = 1
      vim.g.gruvbox_material_foreground = 'original'
      vim.cmd.colorscheme('gruvbox-material')
    end
  },
  -- statusline
  {
    'ojroques/nvim-hardline',
    config = true
  },
  -- debug adapter protocol
  -- https://github.com/mfussenegger/nvim-dap
  {'mfussenegger/nvim-dap'},

  -- linter lsp integration
  -- https://github.com/mfussenegger/nvim-lint
  -- use 'mfussenegger/nvim-lint'

  -- formatter integration
  -- https://github.com/mhartington/formatter.nvim
  { 'mhartington/formatter.nvim' },

  -- Treesitter!
  {
    'nvim-treesitter/nvim-treesitter',
    build = function()
      require("nvim-treesitter.install").update({ with_sync = true })
    end,
    dependencies = {
      {'nvim-treesitter/nvim-treesitter-context'},
    },
    config = function(_, opts)
      require("nvim-treesitter.configs").setup(opts)
    end,
    opts = {
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
        'gdscript',
        'git_rebase',
        'gitattributes',
        'gitignore',
        'godot_resource',
        'graphql',
        'html',
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
        'typescript',
        'vim',
        'vimdoc',
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
    }
  },

  -- smart indentation based on treesitter. ref to experiment later
  -- use({ "yioneko/nvim-yati", tag = "*", requires = "nvim-treesitter/nvim-treesitter" })

  -- Telescope!
  --use 'nvim-lua/popup.nvim'
  {
    'nvim-telescope/telescope.nvim',
    branch = '0.1.x',
    dependencies = {
      {'nvim-lua/plenary.nvim'},
      {'folke/trouble.nvim'}
    },
    config = function()
      local actions = require('telescope.actions')
      local trouble = require("trouble.providers.telescope")
      require("telescope").setup({
        defaults = {
          mappings = {
            i = {
              ["<C-w>"] = actions.send_selected_to_qflist,
              ["<C-q>"] = actions.send_to_qflist,
              ["<C-t>"] = trouble.open_with_trouble,
            },
            n = {
              ["<C-w>"] = actions.send_selected_to_qflist,
              ["<C-q>"] = actions.send_to_qflist,
              ["<C-t>"] = trouble.open_with_trouble,
            },
          }
        }
      })
      local utils = require("jhofer.utils")
      local builtin = require('telescope.builtin')
      utils.nnoremap('<leader>ff', function() builtin.find_files() end)
      utils.nnoremap('<leader>faf', function() builtin.find_files({hidden=true}) end)
      utils.nnoremap('<leader>fg', function() builtin.live_grep() end)
      utils.nnoremap('<leader>fb', function() builtin.buffers() end)
      utils.nnoremap('<leader>fh', function() builtin.help_tags() end)
    end
  },

  -- HARPOOOON
  -- use 'ThePrimeagen/harpoon'

  -- Fugitive!
  --use 'tpope/vim-fugitive'
  --use 'junegunn/gv.vim'

  -- diagnostics, the nice way
  {
    'kyazdani42/nvim-web-devicons',
    config = true
  },
  {
    'folke/trouble.nvim',
    config = function ()
      local trouble = require('trouble')
      trouble.setup()

      local utils = require("jhofer.utils")

      utils.nnoremap("<leader>tx", function() trouble.toggle() end,
        {silent = true}
      )
      utils.nnoremap("<leader>tw", function() trouble.toggle({mode="workspace_diagnostics"}) end,
        {silent = true}
      )
      utils.nnoremap("<leader>td", function() trouble.toggle({mode="document_diagnostics"}) end,
        {silent = true}
      )
      utils.nnoremap("<leader>tl", function() trouble.toggle({mode="loclist"}) end,
        {silent = true}
      )
      utils.nnoremap("<leader>tq", function() trouble.toggle({mode="quickfix"}) end,
        {silent = true}
      )
      -- open all references to thing under cursor
      utils.nnoremap("gR", function() trouble.toggle({mode="lsp_references"}) end,
        {silent = true}
      )
      -- jump to the next item, skipping the groups
      utils.nnoremap("<leader>tn", function() trouble.next({skip_groups = true, jump = true}) end);

      -- jump to the previous item, skipping the groups
      utils.nnoremap("<leader>tp", function() trouble.previous({skip_groups = true, jump = true}) end);

      -- jump to the first item, skipping the groups
      utils.nnoremap("<leader>tf", function() trouble.first({skip_groups = true, jump = true}) end);

      -- jump to the last item, skipping the groups
      utils.nnoremap("<leader>te", function() trouble.last({skip_groups = true, jump = true}) end);
    end
  },
  {
    'VonHeikemen/lsp-zero.nvim',
    branch = 'v2.x',
    dependencies = {
      -- LSP Support
      {'neovim/nvim-lspconfig'},             -- Required
      {
        'williamboman/mason.nvim',
        build = function()
          pcall(vim.cmd, 'MasonUpdate')
        end,
      }, -- Optional
      {'williamboman/mason-lspconfig.nvim'}, -- Optional

      -- Autocompletion
      {'hrsh7th/nvim-cmp'},         -- Required
      {'hrsh7th/cmp-nvim-lsp'},     -- Required
      {'hrsh7th/cmp-buffer'},       -- Optional
      {'hrsh7th/cmp-path'},         -- Optional
      {'saadparwaiz1/cmp_luasnip'}, -- Optional
      {'hrsh7th/cmp-nvim-lua'},     -- Optional

      -- Snippets
      {'L3MON4D3/LuaSnip'},             -- Required
      {'rafamadriz/friendly-snippets'}, -- Optional
    },
    config = function()
      -- set mason settings before calling lsp-zero if overriding things
      -- require("mason.settings").set({})
      local lsp = require('lsp-zero').preset({
        name = 'minimal',
        set_lsp_keymaps = false, -- don't set lsp-zero defaults, use mine
        manage_nvim_cmp = {
          set_sources = 'recommended',
          set_basic_mappings = true,
          set_extra_mappings = true,
          use_luasnip = true,
          set_format = true,
          documentation_window = true
        },
        suggest_lsp_servers = false,
      })

      -- set lsp keybindings
      local utils = require("jhofer.utils")

      lsp.on_attach(function(_, bufnr) -- client, bufnr
        lsp.default_keymaps({buffer = bufnr, omit={'gi'}})
        local bufopts = { buffer=bufnr }
        -- lsp bindings for various awesomeness
        -- jump to definition of symbol. default gd
        utils.nnoremap('<leader>ld', function() vim.lsp.buf.definition() end, bufopts)
        -- jump to global definition of symbol. default gD
        utils.nnoremap('<leader>lD', function() vim.lsp.buf.declaration() end, bufopts)
        -- jump to implementation of symbol. default gi
        utils.nnoremap('<leader>li', function() vim.lsp.buf.implementation() end, bufopts)
        utils.nnoremap('gI', function() vim.lsp.buf.implementation() end, bufopts)
        -- jump to type definition of symbol. default go
        utils.nnoremap('<leader>lo', function() vim.lsp.buf.type_definition() end, bufopts)
        -- display signature info (params, etc.) for symbol. default gs
        utils.nnoremap('<leader>ls', function() vim.lsp.buf.signature_help() end, bufopts)
        -- list all refs to symbol in QF window. default gr
        utils.nnoremap('<leader>lrr', function() vim.lsp.buf.references() end, bufopts)
        -- rename all refs under symbol. default F2
        utils.nnoremap('<leader>lrn', function() vim.lsp.buf.rename() end, bufopts)
        -- format buffer. default F3
        utils.nnoremap('<leader>lf', function() vim.lsp.buf.format() end, bufopts)
        -- display hover info. default K
        utils.nnoremap('<leader>lh', function() vim.lsp.buf.hover() end, bufopts)
        -- select code action at point (need to experiment). default F4
        utils.nnoremap('<leader>lca', function() vim.lsp.buf.code_action() end, bufopts)
        -- Diagnostics Configs
        -- open diagnostic (error) messages in floating window. lsp-zero default gl
        utils.nnoremap('<leader>le', function() vim.diagnostic.open_float() end, bufopts)
        -- move to next diagnostic. lsp-zero default ]d
        utils.nnoremap('<leader>ln', function() vim.diagnostic.goto_next() end, bufopts)
        -- move to prev diagnostic. lsp-zero default [d
        utils.nnoremap('<leader>lp', function() vim.diagnostic.goto_prev() end, bufopts)
      end)

      -- define servers mason should ensure are installed
      lsp.ensure_installed({
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
      })

      lsp.configure('bashls', {
        filetypes = { 'sh', 'zsh', 'bash' }
      })

      lsp.configure('lua_ls', {
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
      })

      lsp.format_on_save({
        format_opts = {
          timeout_ms = 10000
        },
        servers = {}
      })

      lsp.setup()
    end
  },
  {
    'TimUntersberger/neogit',
    dependencies = {
      {'nvim-lua/plenary.nvim'}
    },
    config = true
  },
  {
    "rest-nvim/rest.nvim",
    dependencies = {
      {'nvim-lua/plenary.nvim'}
    },
    config = function()
      require("rest-nvim").setup({
        -- Open request results in a horizontal split
        result_split_horizontal = false,
        -- Keep the http file buffer above|left when split horizontal|vertical
        result_split_in_place = false,
        -- Skip SSL verification, useful for unknown certificates
        skip_ssl_verification = false,
        -- Encode URL before making request
        encode_url = true,
        -- Highlight request on run
        highlight = {
          enabled = true,
          timeout = 150,
        },
        result = {
          -- toggle showing URL, HTTP info, headers at top the of result window
          show_url = true,
          show_http_info = true,
          show_headers = true,
          -- executables or functions for formatting response body [optional]
          -- set them to false if you want to disable them
          formatters = {
            json = "jq",
            html = function(body)
              return vim.fn.system({"tidy", "-i", "-q", "-"}, body)
            end
          },
        },
        -- Jump to request line on run
        jump_to_request = false,
        env_file = '.env',
        custom_dynamic_variables = {},
        yank_dry_run = true,
      })
    end
  },
  {
    "gnikdroy/projections.nvim", -- https://github.com/GnikDroy/projections.nvim
    dependencies = {
      {'nvim-telescope/telescope.nvim'}
    },
    config = function()
      local domain_config = require("domain").get_domain_config()
      require("projections").setup({
        workspaces = domain_config.plugins.projections.workspaces,
        -- patterns = { ".git", ".svn", ".hg" },      -- Default patterns to use if none were specified. These are NOT regexps.
        -- store_hooks = { pre = nil, post = nil },   -- pre and post hooks for store_session, callable | nil
        -- restore_hooks = { pre = nil, post = nil }, -- pre and post hooks for restore_session, callable | nil
        -- workspaces_file = "path/to/file",          -- Path to workspaces json file
        -- sessions_directory = "path/to/dir",        -- Directory where sessions are stored
      })

      -- Bind <leader>fp to Telescope projections
      require('telescope').load_extension('projections')
      local utils = require("jhofer.utils")
      utils.nnoremap('<leader>fp', function() vim.cmd("Telescope projections") end)

      -- Autostore session on VimExit
      local Session = require("projections.session")
      vim.api.nvim_create_autocmd({ 'VimLeavePre' }, {
        callback = function() Session.store(vim.loop.cwd()) end,
      })

      -- Auto Load session on VimEnter
      vim.api.nvim_create_autocmd({ "VimEnter" }, {
        callback = function()
          if vim.fn.argc() ~= 0 then return end
          local session_info = Session.info(vim.loop.cwd())

          if session_info ~= nil then
            Session.restore(vim.loop.cwd())
          end
        end,
        desc = "Restore last session automatically"
      })
    end
  }
}
