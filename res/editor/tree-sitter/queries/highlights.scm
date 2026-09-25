; Literals

(comment) @comment
(shebang) @comment
(string) @string
(buffer) @string.special
(raw_string) @string
(raw_string) @dedented_string
(raw_buffer) @string.special
(string_content) @string
(escape_sequence) @string.escape
(number) @number
(keyword) @string.special.symbol
(nil) @constant.builtin
[(true) (false)] @boolean

; Names

(symbol) @variable

(call
  . (symbol) @function.call)

; Special forms and the macros that stand for control flow or binding.

(call
  . (symbol) @keyword
  (#any-of? @keyword
    "break" "def" "do" "fn" "if" "quasiquote" "quote" "set" "splice"
    "unquote" "upscope" "var" "while"
    "def-" "defn" "defn-" "defmacro" "defmacro-" "var-" "varfn" "defdyn"
    "and" "or" "when" "unless" "if-not" "if-let" "when-let" "if-with"
    "when-with" "cond" "case" "match" "let" "loop" "for" "forv" "each"
    "eachk" "eachp" "repeat" "forever" "seq" "catseq" "tabseq" "generate"
    "coro" "fiber-fn" "try" "protect" "defer" "edefer" "prompt" "label"
    "with" "with-dyns" "with-env" "with-vars" "with-syms" "as-macro"
    "comptime" "compif" "compwhen" "import" "use" "delay" "short-fn"
    "assert" "assertf" "default" "comment" "doc" "toggle"
    "->" "->>" "-?>" "-?>>" "as->" "as?->" "++" "--" "+=" "-=" "*=" "/=" "%="))

; Names a definition or an assignment binds

(call
  . (symbol) @_head
  . (symbol) @lvalue
  (#any-of? @_head
    "def" "def-" "var" "var-" "set" "defn" "defn-" "defmacro" "defmacro-"
    "varfn" "defdyn" "for" "forv" "each" "eachk" "eachp"))

(call
  . (symbol) @_head
  . (vector (symbol) @lvalue)
  (#any-of? @_head "def" "def-" "var" "var-"))

(call
  . (symbol) @_head
  . (map (symbol) @lvalue)
  (#any-of? @_head "def" "def-" "var" "var-"))

; Reader syntax

["'" "`" "~" "|"] @operator

[
  "(" ")" "[" "]" "{" "}"
  "#{" "#(" "![" "!(" "!{"
] @punctuation.bracket
