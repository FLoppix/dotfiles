set nocompatible              		"Use latest vim settings

so ~/.vim/plugins.vim			"source our plugins from external file

syntax enable 

colorscheme solarized
set background=dark
set backspace=indent,eol,start		"Backspace behave like any other editor
let mapleader = ","			"Change default leader character to , intead of /
set noerrorbells visualbell t_vb=	"No error bells
set autowriteall			"Auto save when switching the file
set complete=.,w,b,u			"Set our desired autocompletion
"-------------Visuals---------------"
set guifont=DroidSansMonoForPowerline_Nerd_Font:h14		"set the guifont for vim with font height
set t_CO=256				"Force terminal color 256 Bit
set number				"Activate line numbers
"set macligatures			"We want fancy symbols, when available
set guioptions-=e			"We dont want gui tabs
set guioptions-=l			"Disable left scroll bar
set guioptions-=L			"Disable left scroll bar in split mode
set guioptions-=r			"Disable right scrollbar
set guioptions-=R			"Disable right scrollbar in split mode



"-------------Mappings---------------"

"Disable highlight after search with space
nmap <Leader>ev :tabedit $MYVIMRC<cr>
"Disable highlight after search with space
nmap <Leader><space> :nohlsearch<cr>	
"Quickly edit the snipptes files
nmap <Leader>es :e ~/.vim/snippets<cr>	
"Quickly edit the vim plugin
nmap <Leader>ep :e ~/.vim/plugins.vim<cr>	
"Edit File in current directory
nmap <Leader>ef :e %:h
"Create File in current directory
nmap <Leader>e :e <C-R>=expand("%:p:h") . "/" <CR>

"-------------Plugins---------------"

"/
"/CtrlP
"/
"Toggle CtrlP
nmap <D-p> :CtrlP<cr>
"Seach for variables, tags, functions
nmap <D-r> :CtrlPBufTag<cr>
"Browse recent files
nmap <D-e> :CtrlPMRUFiles<cr>
"Ignores the specific directory
let g:ctrlp_custom_ignore = 'node_modules\DS_STORE\|git' 
"Specify the the windows order
let g:ctrlp_match_windows = 'top,order:ttb,min:1,max:30,result:30'


"/
"/NerdTree
"/
"let NERDTreeHijackNetrw = 0
"Toggle Nerdtree
nmap <D-1> :NERDTreeToggle<cr>

"/
"/Ctags
"/1
nmap <Leader>f :tag<space>

"/
"/PeepOpen
"/
"nmap <D-p> <Plug>PeepOpen

"/
"/Vim-Arline
"/
set laststatus=2 			"Set airline statusbar to show everywhere
let g:airline#extensions#tabline#enabled = 1 "Enable tabs
let g:airline_powerline_fonts = 1	"Use powerline fonts

"/
"/Syntastic
"/
set statusline+=%#warningmsg#
set statusline+=%{SyntasticStatuslineFlag()}
set statusline+=%*

let g:syntastic_always_populate_loc_list = 1
let g:syntastic_auto_loc_list = 1
let g:syntastic_check_on_open = 1
let g:syntastic_check_on_wq = 0

"/
"/Snipmate
"/
"/imap sss <esc>a<Plug>snipMateNextOrTrigger
"/smap sss <Plug>snipMateNextOrTrigger
"-------------Split-Management---------------"
set splitbelow				"Default split below current window!
set splitright 				"Default split to the right
nmap <C-J> <C-W><C-J>			"Switch to the below panel
nmap <C-K> <C-W><C-K>			"Switch to the upper panel
nmap <C-H> <C-W><C-H>			"Switch to the right panel
nmap <C-L> <C-W><C-L>			"Switch to the left panel





"-----------Search------------------"
set hlsearch				"Highlight the search with /$SEARCHSTRING"
set incsearch				"starts highlight the first letter in your search und increments highlighting"






"------------Auto-Commands-----------"
"Automatically source the vimrc file on save.
augroup autosaving
	autocmd BufWritePost .vimrc source %
augroup END
"Auto Compile java files with F9 und cycle with F10 and F11 through the erros
autocmd Filetype java set makeprg=javac\ %
autocmd! FileType c,cpp,java,php call CSyntaxAfter()
set errorformat=%A%f:%l:\ %m,%-Z%p^,%-C%.%#
map <F9> :make<Return>:copen<Return>
map <F10> :cprevious<Return>
map <F11> :cnext<Return>


"-----------Tipps and Tricks----------"
"Press zz to center screen where your cursor is
":bp for previous buffer
":bNUMBER to switch to specific buffer
":ls list all buffers
"$ go to end of line
"A append to end of line 
"X backspace 
"x delete char
"gg go to first line 
"G go to the last line
"b previous word
"B previous WORD
"d delete
"c change
"v visual mode
"V visual line
"R replace mode
"CTRL-R Redo
". repeat cmd
"CTRL-W, q close split view
"$LINENUMBER G/gg  go to line 
"CTRL-^ switch to previous file
"CTRL-D jump down in fils 
"CTRL-D search for files only in CTRL-P Plugin
":tabn new tab
"gt to switch between tabs
"vi$CHARACTER$ select everything between the character
"di$CHARACTER$ delete everything between the character
"ci$CHARACTER$ change everything between the character
"tn next tag in ctags
"tp previous tag
"ts list all tags
"Ctrl-] jump to function declaration
"cs $CHARACATER - change surrounding $CHARACATER
"ds $CHARACTER - delete surrounding $CHARACTER
"cst $CHARACTER - change tag 
"dst $CHARACTER - delete tag
"sbuffer $BUFFERNUMMER	split buffernumber
