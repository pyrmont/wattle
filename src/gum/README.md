# Gum

Gum contains optional Wattle source modules distributed with Wattle. The
runtime does not load these modules automatically. A project copies the
modules it uses into its own source tree and imports them by relative path.
The image generator evaluates `args.wattle` for the `wattle` command line, so
that module is also part of the core image.

## Copying modules

`wattle gum` copies modules from `<prefix>/share/wattle/src/gum` into a
project. `modules.edn` in that directory is a vector of maps, one for each
module, which the command reads with `edn/decode` and the `:p` flag. A module's
map has the `:name` a caller gives the command, the `:files` the module
consists of, which are its source, and a `:help` description.
With `:p`, a description can be wrapped in the file: each line after the first
loses the spaces that begin the second, and the lines are joined with a space.
A description is one paragraph, so it has no blank line.

With no arguments, the command prints `Available modules:`, a blank line and
then each module's name and description in two columns, laid out as the usage
text is: the names are indented by one space and aligned, and the descriptions
wrap at the width of the terminal, up to 120 columns.

With one or more names, it copies the files of each module into `<dir>/gum/`,
creating the directories that are missing. `<dir>` is `deps`, or the argument
of `--dir`, which has the short form `-d`. The command prints one line for each
file, `copied` or `unchanged`, followed by its path.

The command checks every name and every destination before it copies a file.
A name that `modules.edn` does not list, or a destination file that exists
with content that differs from the source, is reported and the command exits
with status 1 having copied nothing. `--force`, which has the short form `-f`,
replaces the differing files. A destination file with the same content as the
source is left as it is. A project can edit its vendored copy, and a later call
does not overwrite the edit unless `--force` is given.

## Arguments

`args.wattle` parses command-line arguments and formats usage text. It is a
Wattle port of Argy-Bargy. Copy `args.wattle` into a
project's `gum/` directory with `wattle gum args`, then import it from the
caller. With the default `--dir`, the copy is in `deps/gum/`:

```clojure
(import ./deps/gum/args :as args)
```

The import path is relative to the importing file. A project can edit its
vendored copy without changing Wattle's source package.

Usage text wraps at the width of the terminal standard output is open on, up to
the `:max-width` of the config's `:info` map, 120 columns by default. When
standard output is not a terminal, or the build registers no `os/term-size`, as
with `-Dreduced-os=true`, it wraps at `:max-width`. `args.wattle` loads in either
build.

`format-columns` takes a sequence of `[name description]` pairs and returns
them as the two columns the usage text uses. Each name is indented by one space,
the descriptions start in one column four columns after the longest name, and a
description wraps at the terminal width described above. An optional second
argument replaces the 120-column maximum. `wattle gum` prints its list of
modules with it.

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
`test.wattle` into a project's `gum/` directory with
`wattle gum test`. A test file imports it and ends with a call to `run-tests!`:

```clojure
(import ../deps/gum/test :prefix "")

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
