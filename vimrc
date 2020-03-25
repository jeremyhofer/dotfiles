" ----- vim-plug settings -----------------------------------------------------
" automatically install if not done already
if empty(glob('~/.vim/autoload/plug.vim'))
  silent !curl -fLo ~/.vim/autoload/plug.vim --create-dirs
    \ https://raw.githubusercontent.com/junegunn/vim-plug/master/plug.vim
endif

" begin
call plug#begin('~/.vim/plugged')

" Orgmode!! plus needed dependencies
Plug 'jceb/vim-orgmode'
Plug 'vim-scripts/utl.vim'

" tags are awesome!
Plug 'fuego0607/taglist.vim'
Plug 'majutsushi/tagbar'

" properly handle inc/dec dates
Plug 'tpope/vim-speeddating'

" allow things to repeat!
Plug 'tpope/vim-repeat'

" GD script syntax for godot
Plug 'calviken/vim-gdscript3'

" to allow registering for :help plug-options
Plug 'junegunn/vim-plug'

" for gitgutter support
Plug 'airblade/vim-gitgutter'

" for editorconfig support
Plug 'editorconfig/editorconfig-vim'

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
syntax enable        " color is awesome
colorscheme monokai

" allow backspacing over everything in insert mode
set backspace=indent,eol,start

set nocompatible       " screw vi!
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
set mouse=a            " always allow the mouse to do mouse things
set path+=**           " to help with fuzzy finding files
set wildmenu           " for file searching

" Don't litter swp files everywhere
set backupdir=~/.cache
set directory=~/.cache

" Command to generate ctags for a codebase
command! MakeTags !ctags -R .

" Tweaks for browsing
let g:netrw_banner=0        " disable annoying banner
let g:netrw_browse_split=4  " open in prior window
let g:netrw_altv=1          " open splits to the right
let g:netrw_liststyle=3     " tree view
let g:netrw_list_hide=netrw_gitignore#Hide()
let g:netrw_list_hide.=',\(^\|\s\s\)\zs\.\S\+'

" The following are handled by editorconfig
"set expandtab          " Expand tabs into spaces
"set encoding=utf-8     " because non utf-8 is weird
"set tabstop=4          " default to 2 spaces for a hard tab
"set softtabstop=4      " default to 2 spaces for the soft tab
"set shiftwidth=4       " for when <TAB> is pressed at the beginning of a line

set hidden             " allows switching buffers without saving files

" Enable folding
set foldmethod=syntax

" R syntax
au BufNewFile,BufRead *.Rmd  set syntax=r

" Yaml syntax
au BufNewFile,BufRead *.yaml,*.yml,*.cwl set filetype=yaml

" wrap at 80 characters for markdown
au BufRead, BufNewFile *.md setlocal textwidth=80

" ----- Plugin Specific Settings ---------------------------------------------
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
