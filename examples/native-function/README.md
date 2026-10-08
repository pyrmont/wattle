# native-function

A native Wattle module written in Zig that demonstrates access to built-in
types. The module API exposes types as views or capabilities. This example uses
views; `examples/native-abstract` demonstrates capabilities by declaring an
abstract type, allocating its payload and defining its callbacks.

Bindings for C libraries commonly read arguments, call the library and return a
result without managing a runtime resource. `url.zig` demonstrates that pattern
and implements the entire module:

```clojure
(import url)

(url/slug "Hello, World!" [:lower])   ; -> "hello-world"
(url/query {:page 2 :sort :name})     ; -> "sort=name&page=2", in hash order
(url/cut "abcdef" 1 -1)               ; -> "bcdef"
(url/parse-query "a=1&b=2")           ; -> {:a "1" :b "2"}
```

`zig build test` builds the module and runs
`examples/native-function/test/url.wattle` against it. The test uses `import*`
to load the shared object. Its path is passed as an argument because the build
places it in Zig's cache, outside `WATTLE_PREFIX`. After the import, the test
uses the same calls as an installed module.

## Module interface

Three getters provide uniform access to groups of Wattle aggregate types.

### Getters

| the getter | the types | what the module gets |
| --- | --- | --- |
| `getBytes` | string, symbol, keyword, buffer | `[]const u8` |
| `getIndexed` | array, vector, tuple | `Indexed` |
| `getDictionary` | table, map | `Dictionary` |

Each has a `Value` form beside it: `wattle.bytesView`, `wattle.toIndexed` and
`wattle.toDictionary`, which return `null` where the getter would raise.

`getIndexed` also reads an abstract whose contents are elements, and
`getDictionary` reads an abstract whose contents are pairs. A vector's elements,
a map's pairs and an abstract's contents may be in more than one run, so
`Indexed` is read with `next`, `get` or `nextChunk` rather than as a slice, and
`Dictionary` with `next` or `nextChunk`.

### Construction

Constructors accept the types returned by the corresponding getters. For
example, `wattle.string(try wattle.getBytes(argv, 0))` type-checks.
`parse-query` builds a map from subslices of the bytes returned by `getBytes`.
The module neither copies those bytes nor recomputes their lengths. The runtime
interns its own copy, allowing the map to outlive the argument. Reusing getter
result types avoids additional shared types for construction.

`slug` calls `getBytes` and `getIndexed`, `query` calls `getDictionary`, `cut`
takes a range, and `parse-query` builds a map. Maps and tables have no
guaranteed iteration order. `query` returns hash order, so callers requiring a
stable string must sort the result. The test sorts the output to avoid requiring
a particular order. It checks each nfunction with multiple types accepted by its
getter. The uniform interface allows code written for tuples to accept arrays or
vectors unchanged.

### Result lifetimes

The module reads getter results without retaining them. String, symbol and
keyword bytes remain stable while the value is reachable. Buffer, array and
table storage is exposed as `data[0..count]` and can move on a push or put. Each
getter documents its result's lifetime. The module must finish using a result
within the call that obtained it; all three nfunctions follow this rule.

### Errors

The runtime rejects incorrect argument types with the same message used for C
modules:

```
(url/slug 3)
; bad slot #0, expected buffer, string, symbol or keyword, got 3
```

The module rejects unknown options through `wattle.panicFormat`:

```
(url/slug "a b" [:bogus])
; unknown option :bogus
```

### Option lookup

The original C module creates a `JanetTable` on first use, inserts each option,
roots it with `janet_gcroot` and looks up keywords with `janet_table_get`. This
module uses `std.StaticStringMap` because both option names and values are known
at compile time. It requires no runtime table, GC root or collector traversal.

### Value access

Each getter has a form accepting a `Value` directly. `wattle.getBytes(argv, n)`
reads an argument slot; `wattle.bytesView(v)` reads any value and returns null
on a type mismatch. `query` uses `bytesView` for dictionary entries, allowing
its error message to identify the caller's key instead of an argument slot.

Slot getters accept any value slice and an index. For example,
`wattle.getNumber(chunk, i)` can read a chunk returned by `nextChunk`. Reading a
tuple of numbers requires no additional getter family.

## External builds

Use the `numarray` build procedure in `examples/native-abstract/README.md` for
an external package's `build.zig.zon` and `build.zig`.
`zig build examples/native-consumer` checks that build interface.
