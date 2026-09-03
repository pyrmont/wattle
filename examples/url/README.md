# url

A native Janet module written in Zig, and the worked example of the **views**
— `DESIGN.md` section 15's other half.

`examples/numarray` is the example of a module that *owns* something: it
declares an abstract type, allocates a payload and fills in the type's slots.
Most native modules are not that. A binding around a C library is usually a
translator — arguments in, work in the library, an answer out — and what it
needs from the runtime is the ability to read what it was handed.

`url.zig` is the whole module, and it owns nothing:

```janet
(import url)

(url/slug "Hello, World!" [:lower])   # -> "hello-world"
(url/query {:page 2 :sort :name})     # -> "sort=name&page=2", in hash order
(url/cut "abcdef" 1 -1)               # -> "bcde"
(url/parse-query "a=1&b=2")           # -> {:a "1" :b "2"}
```

    zig build test

builds it and runs `test/url.janet` against it. That file is an ordinary
`import*` of the built shared object — the path is an argument only because
`zig build` leaves the object in its cache rather than on `JANET_PATH`, and
everything after the import is what someone who had installed the module would
write.

## What it shows

**Three views cover every Janet aggregate an argument can be**, and each is a
pair of types that read identically:

| the view | the pair | what the module gets |
| --- | --- | --- |
| bytes | string, symbol, keyword, buffer | `[]const u8` |
| indexed | tuple, array | `[]const Value` |
| dictionary | struct, table | `DictView` |

Each has a `Value` form beside it — `bytesView`, `indexedView`,
`dictionaryView` — which answers `null` where the getter would raise.

**Construction is the views run backwards.** A constructor takes exactly what
the getter of the same type answers, so `string(try getBytes(argv, 0))`
type-checks and so does `tuple(try getIndexed(argv, 0))`. `parse-query` is the
worked instance: it reads a bytes view and builds a struct out of slices of it,
with no copy and no length recomputed *on the module's side* — the runtime
interns its own copy, which is what lets the struct outlive the argument. That symmetry is not a coincidence —
it is what the rule in `DESIGN.md` §15 predicts, and it is why construction
needed no new shared type.

`slug` reads the first two, `query` reads the third, `cut` takes a range, and
`parse-query` builds one.
Nothing about a struct or a table promises an order, so `query` answers in hash
order and a caller that needs a stable string sorts it — which is what the test
file does rather than pinning one arrangement.
The test file asserts each of them on *both* members of its pair, because that
is the property a view has: a module written for a tuple works on an array
without knowing it.

**A view is read, never stored.** A string's, a symbol's and a keyword's bytes
are stable while the value is reachable. A buffer's, an array's and a table's
are not — they are `data[0..count]`, and a push or a put may move them. Every
getter's doc comment says which of the two it hands back; the rule is to finish
with a view inside the call that obtained it, which is what these three do.

**The refusals come from two places, and the difference matters.** A wrong
argument *type* is the runtime's to refuse, and it does — with the same message
a C module got:

```
(url/slug 3)
# bad slot #0, expected string, symbol, keyword or buffer, got 3
```

An unknown *option* is not a type error, and the runtime has nothing to say
about it. That one is the module's, through `janet.panicFormat`:

```
(url/slug "a b" [:bogus])
# unknown option :bogus
```

**The option table is a `std.StaticStringMap`.** The C module this shape is
taken from builds a `JanetTable` at first use, roots it with `janet_gcroot` so
the collector cannot take it, and looks a keyword up in it with
`janet_table_get`. That is a table, a root, one put per option and a get, all
to map a name known at compile time to a value known at compile time. Zig has
that map already, so this module asks the runtime for none of it and leaves the
collector nothing to traverse.

**Each getter has a `Value` form, and that is what reads an element out of a
view.** `getBytes(argv, n)` takes an argument *slot*; a value pulled out of a
dictionary is in no slot, so `bytesView(v)` takes the value and answers nothing
rather than raising. `query` uses it, and the refusal that follows names the
key the caller wrote instead of a slot number they cannot see.

Where the value *is* an argument slot, the getters need no help: they take any
slice of values and an index into it, so `getNumber(items, i)` over what
`getIndexed` returned is already legal and a tuple of numbers needs no second
family of functions.

## Building one outside this repository

The same way `numarray` does, and `examples/numarray/README.md` has the
`build.zig.zon` and `build.zig` an outside package needs. `zig build standalone`
is the proof that it works.
