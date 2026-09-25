# Neovim

Support for reading and writing `.wattle` source in Neovim. The directory is a
Neovim runtime path. Highlighting comes from the grammar in
`../tree-sitter/`. `zig build` does not build either.

| path        | contents                                                          |
| ----------- | ----------------------------------------------------------------- |
| `ftdetect/` | the `wattle` filetype for `*.wattle`                              |
| `ftplugin/` | comment string, Lisp indenting, `"` unpairing, Tree-sitter start  |
| `syntax/`   | string and comment groups for vim-sexp                            |

## Install with lazy.nvim

Add the directory as a plugin, register the parser and install it. `queries`
links the grammar's query files into nvim-treesitter's query directory.

```lua
{
  dir = "~/Developer/Wattle/wattle/res/editor/nvim",
  name = "wattle",
  dependencies = { "nvim-treesitter/nvim-treesitter" },
  init = function()
    vim.api.nvim_create_autocmd("User", {
      pattern = "TSUpdate",
      callback = function()
        require("nvim-treesitter.parsers").wattle = {
          install_info = {
            path = "~/Developer/Wattle/wattle/res/editor/tree-sitter",
            generate = true,
            queries = "queries",
          },
        }
      end,
    })
  end,
}
```

Then run `:TSInstall wattle`. `generate = true` is needed because the parser
source is not checked in, and it requires the `tree-sitter` command. Run
`:TSUpdate wattle` after a change to the grammar.

`ftplugin/wattle.lua` starts Tree-sitter itself and sets `lisp`, so leave
`wattle` out of a list of parsers that also sets `indentexpr`. The Tree-sitter
indent query is not provided.

## vim-sexp

Add `wattle` to the filetypes and give it the prefix characters:

```lua
vim.g["sexp_filetypes"] = "clojure,scheme,lisp,janet,fennel,wattle"
vim.g["sexp_filetype_macro_characters"] = {
  wattle = "'`~|#!",
}
```

`#` and `!` are in the list so that `#{`, `#(`, `![`, `!(` and `!{` move as one
delimiter. `syntax/wattle.vim` exists because vim-sexp reads the syntax group
under the cursor to tell a string or a comment from code. Whether vim-sexp
treats `,` as whitespace has not been checked.
