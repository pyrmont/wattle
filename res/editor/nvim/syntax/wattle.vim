" Vim syntax for Wattle, for plugins that read syntax groups.
"
" vim-sexp decides whether the cursor is in a string or a comment from the
" syntax group under it. The Tree-sitter highlights do not set one, so this
" file names strings and comments and nothing else.

if exists("b:current_syntax")
  finish
endif

syn match wattleShebang /\%^#!.*/
syn match wattleComment /;.*/ contains=NONE
syn region wattleString start=/!\="/ skip=/\\./ end=/"/ oneline
syn region wattleRawString start=/!\=\z("\{3,}\)/ end=/\z1/

hi def link wattleShebang Comment
hi def link wattleComment Comment
hi def link wattleString String
hi def link wattleRawString String

let b:current_syntax = "wattle"
