# Tree-sitter

A Tree-sitter grammar for Wattle source, with highlight and fold queries. An
editor loads it; `zig build` does not build it.

`grammar.js` follows the lexical syntax in the language specification.
`src/scanner.c` reads strings. A run of quotes is counted before it is
classified, so `"` opens a string, `""` is the empty string and `"""` or longer
opens a raw string that only a run of the same length closes. A `!` before the
run makes a buffer.

The grammar accepts more than the runtime's parser. A prefix and its form may
be on different lines, and the parser's dispatch error for `#word` is a syntax
error here. The nodes are `call`, `vector`, `map`, `set`, `short_fn`, `array`,
`table`, `string`, `buffer`, `raw_string`, `raw_buffer`, `number`, `keyword`,
`symbol`, `nil`, `true`, `false`, `quote`, `quasiquote`, `unquote` and
`splice`.

## Building and testing

The generated files `src/parser.c`, `src/grammar.json` and
`src/node-types.json` are ignored. Generate them and run the tests from this
directory:

```sh
tree-sitter generate
tree-sitter test
```

`test/corpus/` holds the cases. A change to `grammar.js` or `src/scanner.c`
adds a case there.

## Queries

`queries/highlights.scm` uses the standard capture names. It also uses two
that are not standard: `@lvalue` for a name that `def`, `var`, `set`, `defn`,
`for` and similar forms bind, and `@dedented_string` for a raw string. A colour
scheme that does not define them leaves those nodes in the default colour.

The keyword lists in `highlights.scm` are copied from the special forms in the
compiler and the macros in the core library. They are updated by hand.
