lua << EOF
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

return require('packer').startup(function(use)
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
  use { 'nvim-treesitter/nvim-treesitter', run = ':TSUpdate' }

  -- Telescope!
  use 'nvim-lua/popup.nvim'
  use 'nvim-lua/plenary.nvim'
  use 'nvim-telescope/telescope.nvim'

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
EOF

"------- General Settings ---------
"set background=dark
let g:gruvbox_material_background='hard'
let g:gruvbox_material_better_performance=1
let g:gruvbox_material_foreground='original'
colorscheme gruvbox-material

set termguicolors
set number " line numbers
set relativenumber " for relative line numbers for jumping up/down
set ruler " show cursor position at bottom of screen
set timeoutlen=3000 " override 1000 min
set ttimeoutlen=100 " override 50 min
set completeopt=longest,menuone,noinsert,noselect " consider trying default
set updatetime=50 " 50ms after no typing to save swp file
set signcolumn=yes " always show sign column
set linebreak " break lines at nice characters
set confirm " default to ask to save a file
set noerrorbells " bells can piss off!
set ignorecase " ignore for searching
set smartcase " ignore ignorecase if we have capitals
set nohlsearch " gets annoying having stuff highlighted
set laststatus " always have status line
set smartindent
set undofile

" below are legacy things. may not need and don't readily use
set bg=dark " - no need to set based on colorscheme?
"set exrc "allow per-project rc's!! - check if I really need/want this
"set splitright " new split to the right of current window - I don't really use splits anymore
"set foldmethod=syntax fold by syntax
"set foldlevelstart=99 " don't fold unless I want to

" all below are defaults in nvim, so redundant
"set spelllang=en_us - en by default
"set showcmd " show partial commands - on by default
"set timeout - on by default
"set backupdir=~/.cache " Don't litter swp files everywhere - default in a nvim dir
"set directory=~/.cache " Don't litter swp files everywhere - default in a nvim dir
"set hidden " allow switching to another file in window without saving original file - on by default
"set more " allow long command stuff to be scrolled back in - default on
"set smarttab - default on

" exit terminal buffer!
tnoremap <ESC> <C-\><C-n>

" life saving copy to system clipboard remaps
nnoremap <leader>y "+y
vnoremap <leader>y "+y
nnoremap <leader>Y gg"+yG
nnoremap <leader>p "+p

" quick buffer navigation
nnoremap <leader>a :bp<cr>
nnoremap <leader>d :bn<cr>
nnoremap <leader>x :bd<cr>

" BEGONE FOUL BEAST
nnoremap <leader>rm :call delete(@%)<cr>

" yank it and slap it down!
nnoremap <leader>rwy ciw<C-r>0

" quick edit config with \v
nnoremap <Leader>v :e $MYVIMRC<cr>

" toggle spell
nnoremap <leader>sp :setlocal spell! spell?<cr>

" all about that Sex(plore) ;)
nnoremap <Leader>n :Sexplore<cr>

" close a split
nnoremap <leader>q <C-w>q

" nvim lua plugin configurations
lua << EOF
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
EOF

" use treesitter for folding
set foldmethod=expr
set foldexpr=nvim_treesitter#foldexpr()

" Telescope Bindings
nnoremap <leader>ff :lua require('telescope.builtin').find_files()<cr>
nnoremap <leader>faf :lua require('telescope.builtin').find_files({hidden=true})<cr>
nnoremap <leader>fg :lua require('telescope.builtin').live_grep()<cr>
nnoremap <leader>fb :lua require('telescope.builtin').buffers()<cr>
nnoremap <leader>fh :lua require('telescope.builtin').help_tags()<cr>

" lsp bindings for various awesomeness
" jump to definition of symbol
nnoremap <leader>ld :lua vim.lsp.buf.definition()<CR>
" jump to implementation of symbol
nnoremap <leader>li :lua vim.lsp.buf.implementation()<CR>
" display signature info (params, etc.) for symbol
nnoremap <leader>ls :lua vim.lsp.buf.signature_help()<CR>
" list all refs to symbol in QF window
nnoremap <leader>lrr :lua vim.lsp.buf.references()<CR>
" rename all refs under symbol
nnoremap <leader>lrn :lua vim.lsp.buf.rename()<CR>
" nnoremap <leader>lh :lua vim.lsp.buf.hover()<CR>
" select code action at point (need to experiment)
nnoremap <leader>lca :lua vim.lsp.buf.code_action()<CR>
" open diagnostic (error) messages in floating window
nnoremap <leader>le :lua vim.diagnostic.open_float();<CR>
" move to next diagnostic
nnoremap <leader>ln :lua vim.lsp.diagnostic.goto_next()<CR>

" config for netrw built in file browser - set up similar to Nerdtree
let g:netrw_banner = 0
let g:netrw_liststyle = 3
let g:netrw_altv = 1
let g:netrw_winsize = 25

" set width to 80 for markdown
au BufRead,BufNewFile *.md setlocal textwidth=80

" override filetype for specific files
au BufRead,BufNewFile Snakefile setlocal filetype=python

au BufRead,BufNewFile *.envrc setlocal filetype=sh

au BufRead,BufNewFile *.mdx setlocal filetype=markdown

au BufRead,BufNewFile zshrc setlocal filetype=zsh
au BufRead,BufNewFile zprofile setlocal filetype=zsh

" toggle relative numbers on insert mode enter/exit
augroup numbertoggle
    autocmd!
    autocmd BufEnter,FocusGained,InsertLeave * set relativenumber
    autocmd BufLeave,FocusLost,InsertEnter   * set norelativenumber
augroup END

" Reloads vimrc after saving but keep cursor position
if !exists('*ReloadVimrc')
    fun! ReloadVimrc()
        let save_cursor = getcurpos()
        source $MYVIMRC
        call setpos('.', save_cursor)
    endfun
endif
autocmd! BufWritePost $MYVIMRC call ReloadVimrc()
