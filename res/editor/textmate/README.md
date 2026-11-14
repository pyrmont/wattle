# TextMate

A TextMate grammar for Wattle source, `wattle.tmLanguage.json`, with the scope
name `source.wattle` and the file type `wattle`. An editor or highlighter loads
it; `zig build` does not read it.

The grammar follows the lexical syntax in the language specification. Each
pattern matches within a line except a string, which may span lines. A raw
string's end pattern is a backreference to the run of quotes that opened it, so
only a run of the same length closes it. A `!` before a string or a raw string
is part of its opening delimiter, and the scope is the same.

Brackets are matched one at a time, so the grammar does not check nesting. A
call's opening parenthesis and its head are one match, which scopes the head:

| head                                              | scope                   |
| ------------------------------------------------- | ----------------------- |
| `defn`, `defn-`, `defmacro`, `defmacro-`, `varfn` | `storage.type.function` |
| `def`, `def-`, `var`, `var-`, `defdyn`            | `storage.type`          |
| a special form or a control macro                 | `keyword.control`       |
| any other symbol                                  | `entity.name.function`  |

The name after a definition head is `entity.name.function` or
`variable.other.definition`. The list of special forms and control macros is
the one in `../tree-sitter/queries/highlights.scm`; a change to one list is
made to the other.

A word tag such as `#foo`, a form that begins with `@` or `^`, and an escape
that the parser refuses are `invalid.illegal`.
