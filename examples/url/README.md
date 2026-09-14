# url

A native Janet module written in Zig, and the worked example of the built-in
types. `DESIGN.md` section 13 records the decision that a type crosses to a
module author as a view or as a capability. This module is the view half and
`examples/numarray` is the capability half.

`examples/numarray` is the example of a module that owns something: it declares
an abstract type, allocates a payload and fills in the type's slots. Most native
modules are not that. A binding around a C library is usually a translator,
taking arguments in, doing work in the library and returning a result. What it
needs from the runtime is the ability to read what it was given.

`url.zig` is the whole module, and it owns nothing:

```janet
(import url)

(url/slug "Hello, World!" [:lower])   # -> "hello-world"
(url/query {:page 2 :sort :name})     # -> "sort=name&page=2", in hash order
(url/cut "abcdef" 1 -1)               # -> "bcde"
(url/parse-query "a=1&b=2")           # -> {:a "1" :b "2"}
```

    zig build test

builds it and runs `examples/url/test/url.janet` against it. That file is an
ordinary `import*` of the built shared object. The path is an argument only
because `zig build` leaves the object in its cache rather than on `JANET_PATH`,
and everything after the import is what someone who had installed the module
would write.

## What it shows

### The three getters

Three getters cover every Janet aggregate an argument can be, and each reads a
group of types identically:

| the getter | the types | what the module gets |
| --- | --- | --- |
| `getBytes` | string, symbol, keyword, buffer | `[]const u8` |
| `getIndexed` | tuple, array | `[]const Value` |
| `getDictionary` | struct, table | `Pairs` |

Each has a `Value` form beside it: `janet.bytesView`, `janet.indexedView` and
`janet.dictionaryView`, which return `null` where the getter would raise.

### Construction as the getters run backwards

A constructor takes exactly what the getter of the same type returns, so
`janet.string(try janet.getBytes(argv, 0))` type-checks and so does
`janet.tuple(try janet.getIndexed(argv, 0))`. `parse-query` is the worked
instance. It reads the slice `getBytes` returns and builds a struct out of
slices of it, with no copy and no length recomputed on the module's side.
The runtime interns its own copy, so the struct outlives the argument. That
symmetry is what the rule in `DESIGN.md` section 13 implies, and it is the
reason construction needed no new shared type.

`slug` calls `getBytes` and `getIndexed`, `query` calls `getDictionary`, `cut`
takes a range, and `parse-query` builds a struct. Nothing about a struct
or a table promises an order, so `query` returns in hash order and a caller that
needs a stable string sorts the result. The test file sorts it rather than
pinning one arrangement. The test file asserts each cfunction on more than one
of the types its getter reads, because a getter reads them identically: a module
written for a tuple works on an array with no change.

### The lifetime of what a getter returns

What a getter returns is read, never stored. A string's, a symbol's and a
keyword's bytes are stable while the value is reachable. A buffer's, an array's
and a table's are not: they are `data[0..count]`, and a push or a put may move
them. Every getter's doc comment says which of the two kinds it returns. The
rule is to finish with what it returned inside the call that obtained it, and
all three cfunctions do so.

### Where a refusal comes from

The refusals come from two places. A wrong argument type is the runtime's to
refuse, and it does, with the same message a C module got:

```
(url/slug 3)
# bad slot #0, expected string, symbol, keyword or buffer, got 3
```

An unknown option is not a type error, and the runtime has nothing to say about
it. That refusal is the module's, through `janet.panicFormat`:

```
(url/slug "a b" [:bogus])
# unknown option :bogus
```

### The option table as a `std.StaticStringMap`

The C module this shape is taken from builds a `JanetTable` at first use, roots
it with `janet_gcroot` so the collector cannot take it, and looks a keyword up
in it with `janet_table_get`: a table, a root, one put per option and a get, all
to map a name known at compile time to a value known at compile time. Zig has
that map already, so this module asks the runtime for none of it and leaves the
collector nothing to traverse.

### A getter's `Value` form

Each getter has a `Value` form, and that is what reads a value with no slot of
its own. `janet.getBytes(argv, n)` takes an argument slot. A value pulled out of
a dictionary entry is in no slot, so `janet.bytesView(v)` takes the value and
returns null rather than raising. `query` uses it, and the refusal that follows
names the key the caller wrote instead of a slot number the caller cannot see.

Where the value is an argument slot, the getters need no help. They take any
slice of values and an index into it, so `janet.getNumber(items, i)` over what
`janet.getIndexed` returned is already legal, and a tuple of numbers needs no
second family of functions.

## Building a module outside this repository

The same way `numarray` does. `examples/numarray/README.md` has the
`build.zig.zon` and `build.zig` an outside package needs, and `zig build
standalone` is the proof that it works.
