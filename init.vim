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

" file explorer
Plug 'preservim/nerdtree'
Plug 'tiagofumo/vim-nerdtree-syntax-highlight'
Plug 'Xuyuanp/nerdtree-git-plugin'
Plug 'tiagofumo/vim-nerdtree-syntax-highlight'

" icons!
Plug 'ryanoasis/vim-devicons'

" airline statusline
Plug 'vim-airline/vim-airline'

"ctrl-p fuzzy find
Plug 'ctrlpvim/ctrlp.vim'

" Initialize plugin system
call plug#end()

"------- General Settings ---------
colorscheme monokai
" set venv python path for nvim helpers
let g:python3_host_prog = '~/.pyenv/versions/3.8.2/envs/py3nvim/bin/python'

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
set updatetime=300 " 300ms after no typing to save swp file set signcolumn=yes " always show sign column
set linebreak " break lines at nice characters
set confirm " default to ask to save a file
set visualbell " visual, not beep
set ignorecase " ignore for searching
set smartcase " ignore ignorecase if we have capitals
set laststatus " always have status line

" toggle relative on insert mode enter/exit
augroup numbertoggle
    autocmd!
    autocmd BufEnter,FocusGained,InsertLeave * set relativenumber
    autocmd BufLeave,FocusLost,InsertEnter   * set norelativenumber
augroup END

" quick edit config with \v
nnoremap <Leader>v :e $MYVIMRC<cr>

" Reloads vimrc after saving but keep cursor position
if !exists('*ReloadVimrc')
    fun! ReloadVimrc()
        let save_cursor = getcurpos()
        source $MYVIMRC
        call setpos('.', save_cursor)
    endfun
endif
autocmd! BufWritePost $MYVIMRC call ReloadVimrc()

" nerdtree settings
nnoremap <Leader>n :NERDTreeToggle<cr>

" ctrlp settings
let g:ctrlp_custom_ignore = 'node_modules'
nnoremap <Leader>f :CtrlPMixed<cr>
