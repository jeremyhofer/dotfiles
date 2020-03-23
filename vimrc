" ----- vim-plug settings -----------------------------------------------------
" automatically install if not done already
if empty(glob('~/.vim/autoload/plug.vim'))
  silent !curl -fLo ~/.vim/autoload/plug.vim --create-dirs
    \ https://raw.githubusercontent.com/junegunn/vim-plug/master/plug.vim
endif

" begin
call plug#begin('~/.vim/plugged')

" GD script syntax for godot
Plug 'calviken/vim-gdscript3'

" to allow registering for :help plug-options
Plug 'junegunn/vim-plug'

" for gitgutter support
Plug 'airblade/vim-gitgutter'

" for editorconfig support
Plug 'editorconfig/editorconfig-vim'

" NERDTree - system tree view for large projects
Plug 'scrooloose/nerdtree'

" multiple cursors, like in Sublime
Plug 'terryma/vim-multiple-cursors'

" surround, for [], {}, etc.
Plug 'tpope/vim-surround'

" pretty status bar
Plug 'vim-airline/vim-airline'

" lint engine
Plug 'w0rp/ale'

" makes nerdtree act/feel more like an extension of the tab, not its own thing
Plug 'jistr/vim-nerdtree-tabs'

" code snippet/template engine
Plug 'drmingdrmer/xptemplate'

" nice pep8 indenting
Plug 'Vimjas/vim-python-pep8-indent'

" nice comment strings
Plug 'scrooloose/nerdcommenter'

" hocon syntax
Plug 'GEverding/vim-hocon'

" wdl syntax
Plug 'broadinstitute/vim-wdl'

" pine script syntax
Plug 'jbmorgado/vim-pine-script'

" themes for the status bar
"vim-airline/vim-airline-themes
" Fuzzy file search - awesome in nerdtree
Plug 'kien/ctrlp.vim'

" MONOKAI COLORS!!
Plug 'crusoexia/vim-monokai'

" git plugin
"tpope/vim-fugitive
" database plugin
"tpope/vim-db
" awesome complete thing
"Valloric/YouCompleteMe
" automatic closing of delimiters
"Raimondi/delimitMate
" insert/delete stuff in pairs
"jiangiao/auto-pairs

" Initialize plugin system
call plug#end()

" ----- General Settings  -----------------------------------------------------
filetype plugin on     " Required
syntax on        " color is awesome
colorscheme monokai

" allow backspacing over everything in insert mode
set backspace=indent,eol,start

set history=1000       " keep 1000 lines of command line history
set number             " line numbers
set ruler              " show the cursor position all the time
set showcmd            " display incomplete commands
set incsearch          " do incremental searching
set scrolloff=3        " don't let the cursor touch the edge of the viewport
set splitright         " Vertical splits use right half of screen
set timeoutlen=100     " Lower ^[ timeout
set fillchars=fold:\ , " get rid of obnoxious '-' characters in folds
set tildeop            " use ~ to toggle case as an operator, not a motion
"set mouse=a            " always allow the mouse to do mouse things

" The following are handled by editorconfig
"set expandtab          " Expand tabs into spaces
"set encoding=utf-8     " because non utf-8 is weird
"set tabstop=4          " default to 2 spaces for a hard tab
"set softtabstop=4      " default to 2 spaces for the soft tab
"set shiftwidth=4       " for when <TAB> is pressed at the beginning of a line

set hidden             " allows switching buffers without saving files

set clipboard=unnamed

" Enable folding
set foldmethod=indent
set foldlevel=99

" To toggle line numbers
nnoremap <C-l> :set nonumber! number?<CR>

" R syntax
au BufNewFile,BufRead *.Rmd  set syntax=r

" Yaml syntax
au BufNewFile,BufRead *.yaml,*.yml,*.cwl set filetype=yaml

" wrap at 80 characters for markdown
au BufRead, BufNewFile *.md setlocal textwidth=80

" ----- Plugin Specific Settings ---------------------------------------------
" NERDTree
nnoremap <C-l> :NERDTreeToggle<CR>

" ALE Fixers
let g:ale_fixers = {
            \'python': ['autopep8'],
            \'perl': ['perltidy'],
            \'ruby': ['rubocop'],
            \'javascript': ['eslint'],
            \'rust': ['rustfmt']
            \}

let g:ale_perl_perlcritic_showrules = 1
let g:ale_perl_perltidy_options = '-l=120'
