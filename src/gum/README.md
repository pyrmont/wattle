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

`args.wattle` uses no OS or process function. Usage text wraps at the `:max-width`
of the config's `:info` map, 120 columns by default, and does not read the
terminal's width.
