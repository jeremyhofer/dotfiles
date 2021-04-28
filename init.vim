" ----- vim-plug settings -----------------------------------------------------
" check whether vim-plug is installed and install it if necessary
let plugpath = expand('<sfile>:p:h'). '/autoload/plug.vim'
if !filereadable(plugpath)
    if executable('curl')
        let plugurl = 'https://raw.githubusercontent.com/junegunn/vim-plug/master/plug.vim'
        call system('curl -fLo ' . shellescape(plugpath) . ' --create-dirs ' . plugurl)
        if v:shell_error
            echom "Error downloading vim-plug. Please install it manually.\n"
            exit
        endif
    else
        echom "vim-plug not installed. Please install it manually or install curl.\n"
        exit
    endif
endif

call plug#begin('~/.config/nvim/plugged')

" to allow registering for :help plug-options
Plug 'junegunn/vim-plug'

" syntax highlighting
"Plug 'pangloss/vim-javascript'
"Plug 'lepture/vim-jinja'
"Plug 'cespare/vim-toml'
"Plug 'tpope/vim-cucumber'
"Plug 'leafgarland/typescript-vim'
"Plug 'calviken/vim-gdscript3'
"Plug 'snakemake/snakemake', {'rtp': 'misc/vim'}
" Plug 'GEverding/vim-hocon'
" Plug 'broadinstitute/vim-wdl'
" Plug 'jbmorgado/vim-pine-script'

" nice pep8 indenting
"Plug 'Vimjas/vim-python-pep8-indent'

" COLORS!!
Plug 'morhetz/gruvbox'
Plug 'phanviet/vim-monokai-pro'
Plug 'crusoexia/vim-monokai'

" for editorconfig support
Plug 'editorconfig/editorconfig-vim'

" multiple cursors, like in Sublime
Plug 'terryma/vim-multiple-cursors'

" icons!
Plug 'ryanoasis/vim-devicons'

" airline statusline
Plug 'vim-airline/vim-airline'

" LSP!!!
Plug 'neovim/nvim-lspconfig'
Plug 'nvim-lua/completion-nvim'

" completion!
Plug 'nvim-lua/completion-nvim'

" Treesitter!
Plug 'nvim-treesitter/nvim-treesitter', {'do': ':TSUpdate'}
"Plug 'tjdevries/nlua.nvim'
Plug 'nvim-treesitter/nvim-treesitter-angular'
"Plug 'nvim-treesitter/nvim-tree-docs'

" Telescope!
Plug 'nvim-lua/popup.nvim'
Plug 'nvim-lua/plenary.nvim'
Plug 'nvim-telescope/telescope.nvim'

" Fugitive!
Plug 'tpope/vim-fugitive'
Plug 'junegunn/gv.vim'

" Initialize plugin system
call plug#end()

"------- General Settings ---------
let g:gruvbox_contrast_dark='hard'
colorscheme gruvbox

set bg=dark
set exrc "allow per-project rc's!!
set termguicolors
set number " line numbers
set relativenumber " for relative line numbers for jumping up/down
set spelllang=en_us
set ruler " show cursor position
set showcmd " show partial commands
set splitright " new split to the right of current window
set timeout timeoutlen=3000 ttimeoutlen=100 " local leader Lower ^[ timeout
set backupdir=~/.cache " Don't litter swp files everywhere
set directory=~/.cache " Don't litter swp files everywhere
set completeopt=longest,menuone,noinsert,noselect
set hidden " allow switching to another file in window without saving original file
set updatetime=300 " 300ms after no typing to save swp file
set signcolumn=yes " always show sign column
set linebreak " break lines at nice characters
set confirm " default to ask to save a file
set noerrorbells " bells can piss off!
set ignorecase " ignore for searching
set smartcase " ignore ignorecase if we have capitals
set nohlsearch " gets annoying having stuff highlighted
set laststatus " always have status line
set more " allow long command stuff to be scrolled back in
set foldmethod=syntax " fold by syntax
set foldlevelstart=99 " don't fold unless I want to

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

" treesitter settings
lua require'nvim-treesitter.configs'.setup { highlight = { enable = true } }

" telescope settings
lua << EOF
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
EOF

nnoremap <leader>ff :lua require('telescope.builtin').find_files()<cr>
nnoremap <leader>fg :lua require('telescope.builtin').live_grep()<cr>
nnoremap <leader>fb :lua require('telescope.builtin').buffers()<cr>
nnoremap <leader>fh :lua require('telescope.builtin').help_tags()<cr>

" LSP/completion settings
let g:completion_matching_strategy_list = ['exact', 'substring', 'fuzzy']
lua << EOF
local lspconfig = require('lspconfig')
lspconfig.tsserver.setup{ on_attach=require'completion'.on_attach }
lspconfig.vuels.setup{ on_attach=require'completion'.on_attach }
lspconfig.jdtls.setup{
  on_attach=require'completion'.on_attach;
  cmd={'jdt-language-server'};
}
EOF

" config for netrw built in file browser - set up similar to Nerdtree
let g:netrw_banner = 0
let g:netrw_liststyle = 3
let g:netrw_altv = 1
let g:netrw_winsize = 25

" set width to 80 for markdown
au BufRead,BufNewFile *.md setlocal textwidth=80

" toggle relative on insert mode enter/exit
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
