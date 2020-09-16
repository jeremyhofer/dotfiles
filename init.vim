" ----- vim-plug settings -----------------------------------------------------
" automatically install if not done already
if empty(glob('~/.vim/autoload/plug.vim'))
  silent !curl -fLo ~/.vim/autoload/plug.vim --create-dirs
    \ https://raw.githubusercontent.com/junegunn/vim-plug/master/plug.vim
endif

" begin
call plug#begin('~/.vim/plugged')

" javascript syntax highlighting
Plug 'pangloss/vim-javascript'

" jinja!!
Plug 'lepture/vim-jinja'

" toml syntax
Plug 'cespare/vim-toml'

" syntax and formatting for cucumber
Plug 'tpope/vim-cucumber'

" syntax for typsescript
Plug 'leafgarland/typescript-vim'

" GD script syntax for godot
Plug 'calviken/vim-gdscript3'

" nice pep8 indenting
Plug 'Vimjas/vim-python-pep8-indent'

" hocon syntax
Plug 'GEverding/vim-hocon'

" wdl syntax
Plug 'broadinstitute/vim-wdl'

" pine script syntax
Plug 'jbmorgado/vim-pine-script'

" Awesome completion
Plug 'neoclide/coc.nvim', {'branch': 'release'}

" MONOKAI COLORS!!
Plug 'crusoexia/vim-monokai'

" to allow registering for :help plug-options
Plug 'junegunn/vim-plug'

" for editorconfig support
Plug 'editorconfig/editorconfig-vim'

" multiple cursors, like in Sublime
Plug 'terryma/vim-multiple-cursors'

" Initialize plugin system
call plug#end()

"set runtimepath^=~/.vim runtimepath+=~/.vim/after
"let &packpath = &runtimepath
"source ~/.vimrc

"------- General Settings ---------
colorscheme monokai
let g:python3_host_prog = '/home/jhofer/.pyenv/versions/3.8.2/envs/py3nvim/bin/python'

set statusline^=%{coc#status()}
set number " line numbers
set relativenumber " for relative line numbers for jumping up/down
set spell spelllang=en_us
set ruler " show cursor position
set showcmd " show partial commands
set splitright " new split to the right of current window
set timeout timeoutlen=3000 ttimeoutlen=100 " local leader Lower ^[ timeout
set path+=** " to help with fuzzy finding files
" Don't litter swp files everywhere
set backupdir=~/.cache
set directory=~/.cache
set completeopt=longest,menuone,preview
set hidden " allow switching to another file in window without saving original file
set updatetime=300 " 300ms after no typing to save swp file
set signcolumn=yes " always show sign column
set linebreak " break lines at nice characters
set confirm " default to ask to save a file
set visualbell " visual, not beep
set ignorecase " ignore for searching
set smartcase " ignore ignorecase if we have capitals
set laststatus " always have status line
