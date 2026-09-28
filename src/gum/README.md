# Gum

Gum contains optional Wattle source modules distributed with Wattle. The
runtime does not compile or load these modules automatically. A project copies
the modules it uses into its own source tree and imports them by relative path.

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
