# Gum

Gum contains optional Wattle source modules distributed with Wattle. The
runtime does not load these modules automatically. A project copies the
modules it uses into its own source tree and imports them by relative path.
The image generator evaluates `args.wattle` for the `wattle` command line, so
that module is also part of the core image.

## Arguments

`args.wattle` parses command-line arguments and formats usage text. It is a
Wattle port of Argy-Bargy. Copy `args.wattle` and `LICENSE.argy-bargy` into a
project's `gum/` directory, then import it from the caller:

```clojure
(import ./gum/args :as args)
```

The import path is relative to the importing file. A project can edit its
vendored copy without changing Wattle's source package.

Usage text wraps at the width of the terminal standard output is open on, up to
the `:max-width` of the config's `:info` map, 120 columns by default. When
standard output is not a terminal, or the build registers no `os/term-size`, as
with `-Dreduced-os=true`, it wraps at `:max-width`. `args.wattle` loads in either
build.

A parameter rule with `:rest?` is a splat that must be the last parameter. It
captures its first token and every token after it as given, options included,
and the parser reads no more options once it has started. A rule with `:splat?`
alone collects only the tokens that are not options, and the parser reads
options between them.

A config with `:subs` may set `:implicit` to the name of one of them. Where the
parser would otherwise report an unrecognized subcommand or option, or that no
subcommand was given, it enters that subcommand with the tokens from that point
as its arguments. Options the config declares itself are read first, so root
options still precede the implicit subcommand's own. A subcommand may have
`:subs` of its own and is parsed in the same way. `help` followed by several
names describes the last one. `h` is read as `help` unless a subcommand is
named or abbreviated `h`.

`parse-args` checks the config's rules and subcommands on every call. A caller
whose config never changes can set `:validate?` to `false` in the config to
skip the check, after running it once with the default.

## Tests

`test.wattle` is a test framework ported from Testament for Janet. Copy
`test.wattle` and `LICENSE.testament` into a project's `gum/` directory. A test
file imports it and ends with a call to `run-tests!`:

```clojure
(import ./gum/test :prefix "")

(deftest one-plus-one
  (is (= 2 (+ 1 1)) "1 + 1 = 2"))

(deftest two-plus-two
  {:skip-when (= :windows (os/which))
   :tags [:arithmetic]}
  (is (= 5 (+ 2 2)) "2 + 2 = 5"))

(run-tests!)
```

`wattle test` runs every `.wattle` file under `./test` in its
own process. It sets the dynamic bindings `:test/tests` and `:test/skips` from
`--test` and `--no-test`, `:test/seed` from `--seed`, and `:test/color?` when
output is a terminal. `run-tests!` reads all four. It exits with status 1 if a test failed unless it
is called with `:no-exit?` set to `true`.

`deftest` takes an optional map after the test name. It is metadata when at
least one form follows it. A `:skip-when` form is compiled into a function in
the scope of the test, and `run-tests!` omits the test when it returns a truthy
value. `is` selects the kind of assertion from the form it is given: `=`,
`deep=`, `==`, `matches`, `thrown?` with one or two arguments, or any other
expression. `==` is true for values whose types differ only in mutability.
`run-tests!` runs the tests in the order they were registered, unless the
dynamic binding `:test/seed` is an integer. Then it shuffles them with that
seed, and the same seed gives the same order. `run-tests!` takes no seed of its
own. `wattle test` sets `:test/runner` to `:wattle`, and the default report then has
the failures and one line of counts in place of the summary, which `wattle test`
reads. It also sets `:test/seed` in every test file from the seed it
prints, so a failed run is reproduced with `--seed`.

A caller in a REPL sets the dynamic binding `:test/repl?` to `true`, so that a
failure does not exit the REPL. `run-tests!` then resets the reports and empties
`module/cache` before it returns.
