vim.bo.commentstring = "; %s"
vim.bo.comments = ":;"
vim.bo.lisp = true
vim.bo.expandtab = true
vim.bo.shiftwidth = 2
vim.bo.softtabstop = 2

-- A symbol may hold any of these, so `w` and `*` move over the whole name.
vim.bo.iskeyword = "@,48-57,_,192-255,!,$,%,&,*,+,-,.,/,<,=,>,?"
-- `lispwords` for the forms that indent their body by two.
vim.opt_local.lispwords:append({
  "defn", "defn-", "defmacro", "defmacro-", "fn", "let", "loop", "for",
  "forv", "each", "eachk", "eachp", "when", "unless", "when-let", "if-let",
  "with", "with-dyns", "with-syms", "try", "protect", "defer", "edefer",
  "match", "case", "cond", "while", "repeat", "generate", "coro",
})

pcall(vim.treesitter.start)

-- vim-sexp pairs `"` and pads a quote that follows a non-blank with a space, so
-- a third `"` after `""` gives `"" "|"`. In Wattle it opens a raw string, so
-- the mapping is removed and a quote types a quote. vim-sexp maps on FileType,
-- so this runs after the handlers have finished.
local buf = vim.api.nvim_get_current_buf()
vim.schedule(function()
  if vim.api.nvim_buf_is_valid(buf) then
    pcall(vim.keymap.del, "i", '"', { buffer = buf })
  end
end)
