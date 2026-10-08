# Gum

Gum contains optional Wattle source modules distributed with Wattle. The runtime
does not load these modules automatically. A project copies the modules it uses
into its own source tree and imports them by relative path. The image generator
evaluates `args.wattle` for the `wattle` command line, so that module is also
part of the core image.

## Copying modules

`wattle gum` copies modules from `<prefix>/share/wattle/src/gum` into a project.
`modules.edn` in that directory is a vector of maps, one for each module. The
command reads it with `edn/decode` and the `:p` flag. Each map specifies the
command argument as `:name`, source files as `:files` and a `:help` description.

With `:p`, descriptions can span lines. Decoding removes the second line's
indentation from subsequent lines and joins them with spaces. Each description
must be a single paragraph without blank lines.

With no arguments, the command prints `Available modules:`, a blank line and
then each module's name and description in two columns, laid out as the usage
text is: the names are indented by one space and aligned, and the descriptions
wrap at the width of the terminal, up to 120 columns.

With one or more names, the command copies each module's files into `<dir>/gum/`
and creates missing directories. It copies the Gum `LICENSE` once per
invocation. `<dir>` is `deps`, or the argument of `--dir`, which has the short
form `-d`. The command prints one line for each file, `copied` or `unchanged`,
followed by its path.

The command checks every name and every destination before it copies a file. A
name that `modules.edn` does not list, or a destination file that exists with
content that differs from the source, is reported and the command exits with
status 1 having copied nothing. `--force`, which has the short form `-f`,
replaces the differing files. A destination file with the same content as the
source is left as it is. A project can edit its vendored copy, and a later call
does not overwrite the edit unless `--force` is given.

## Arguments

`args.wattle` parses command-line arguments and formats usage text. It is a
Wattle port of Argy-Bargy. Copy `args.wattle` into a project's `gum/` directory
with `wattle gum args`, then import it from the caller. With the default
`--dir`, the copy is in `deps/gum/`:

```clojure
(import ./deps/gum/args :as args)
```

The import path is relative to the importing file. A project can edit its
vendored copy without changing Wattle's source package.

Usage text wraps at the width of the terminal standard output is open on, up to
the `:max-width` of the config's `:info` map, 120 columns by default. When
standard output is not a terminal, or the build registers no `os/term-size`, as
with `-Dreduced-os=true`, it wraps at `:max-width`. `args.wattle` loads in
either build.

`format-columns` takes a sequence of `[name description]` pairs and returns them
as the two columns the usage text uses. Each name is indented by one space, the
descriptions start in one column four columns after the longest name, and a
description wraps at the terminal width described above. An optional second
argument replaces the 120-column maximum. `wattle gum` prints its list of
modules with it.

A parameter rule with `:rest?` must be last. It collects every token from its
first match onwards, including options, and stops further option parsing. A rule
with only `:splat?` collects non-option tokens while allowing options between
them.

A config with `:subs` can name an implicit subcommand through `:implicit`. The
parser selects it when a subcommand or option is unrecognised, or no subcommand
is given. Remaining tokens become its arguments. Root options are parsed first,
before the implicit subcommand's options. Nested `:subs` use the same parsing
rules. `help` followed by several names describes the final subcommand. `h`
means `help` unless a subcommand has that name or abbreviation.

`parse-args` checks the config's rules and subcommands on every call. A caller
whose config never changes can set `:validate?` to `false` in the config to skip
the check, after running it once with the default.

## Tests

`test.wattle` is a test framework ported from Testament for Janet. Copy
`test.wattle` into a project's `gum/` directory with `wattle gum test`. A test
file imports it and ends with a call to `run-tests!`:

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

`wattle test` runs each `.wattle` file under `./test` in a separate process. It
sets four dynamic bindings read by `run-tests!`: `:test/tests` from `--test`,
`:test/skips` from `--no-test`, `:test/seed` from `--seed` and `:test/color?`
when output is a terminal. `run-tests!` exits with status 1 on a test failure
unless called with `:no-exit?` set to `true`.

`deftest` takes an optional map after the test name. It is metadata when at
least one form follows it. A `:skip-when` form is compiled into a function in
the scope of the test, and `run-tests!` omits the test when it returns a truthy
value. `is` selects the kind of assertion from the form it is given: `=`,
`deep=`, `==`, `matches`, `thrown?` with one or two arguments, or any other
expression. `==` is true for values whose types differ only in mutability.
`run-tests!` runs the tests in the order they were registered, unless the
dynamic binding `:test/seed` is an integer. Then it shuffles them with that
seed, and the same seed gives the same order. `run-tests!` takes no seed of its
own.

`wattle test` sets `:test/runner` to `:wattle`. The default report then prints
failures and one count line for `wattle test` to read, replacing the summary. It
sets `:test/seed` in every test file to the printed seed. Use that value with
`--seed` to reproduce a failed run.

A caller in a REPL sets the dynamic binding `:test/repl?` to `true`, so that a
failure does not exit the REPL. `run-tests!` then resets the reports and empties
`module/cache` before it returns.
