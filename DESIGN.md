# Design of the Zig Implementation

This document describes the design of the Zig implementation of the Janet
programming language.

---

## Contents

- [Introduction](#introduction)
- [1. Value representation](#1-value-representation)
- [2. The type tag](#2-the-type-tag)
- [3. Heads and payloads](#3-heads-and-payloads)
- [4. Head visibility](#4-head-visibility)
- [5. Value layouts](#5-value-layouts)
- [6. Numbers](#6-numbers)
- [7. Pointer types](#7-pointer-types)
- [8. Raising errors](#8-raising-errors)
- [9. Signal numbers](#9-signal-numbers)
- [10. Public interface](#10-public-interface)
- [11. Built-in types](#11-built-in-types)
- [12. Modules: abstract types](#12-modules-abstract-types)
- [13. Modules: built-in types](#13-modules-built-in-types)
- [14. Modules: functions](#14-modules-functions)
- [15. Modules: re-entry and scheduling](#15-modules-re-entry-and-scheduling)
- [16. The indexed protocol](#16-the-indexed-protocol)

## Introduction

This implementation of the Janet programming language began as an attempt to
explore whether a version of Janet could be written that:

1. does not use `setjmp` and `longjmp`; and
2. works seamlessly with the Zig ecosystem.

What it keeps from the C implementation is the behaviour a program written in
Janet observes: error messages, signal kinds, traces, marshalled bytes,
bytecode and the core image (section 10). A program written in Janet, using
only values Janet can make, behaves as it does on the C implementation, within
reason. Within reason is four kinds of difference, and no others:

- the differences the Naming subsection lists;
- defects in the C implementation that this runtime fixes deliberately;
- new names wherever an environment is enumerated, as by `all-bindings`;
- an error message or docstring that names what a function accepts, where this
  runtime accepts more (section 16).

The promise does not cover a program in which a value only this runtime can
make reaches Janet code. There is no C implementation for that program to
behave as.

What it does not keep is the C interface: `janet.h`. It is a non-goal to support code that relies on the C
ABI, including native modules written in C. The Zig implementation supports
native modules written in Zig.

### Naming

The implementation is called Wattle, and Janet is the name of a language it
runs. `.wattle` source is to be a second language on the same virtual machine,
so the two names mark different things:

- **Wattle** names the product: the package, the `wattle` executable,
  `libwattle`, the module an author imports (`@import("wattle")`), the
  loader's `_wattle_init` and `_wattle_mod_config` symbols, the `WATTLE_PATH`
  and `WATTLE_PROFILE` environment variables, the `/usr/local/lib/wattle`
  syspath, the REPL banner, the `wattle/version` binding, docstrings and
  messages that name the running program (`wattle out of memory`,
  `wattle abort: …`, `os/exit`'s "Exit from Wattle"), and internal names that
  identify this implementation (`wattle_fatal`, `WATTLE_*` host macros, build
  artifacts, Windows' `WattlePipeFile` pipes).
- **Janet** names the language: `.janet` files, the `janet/` bindings
  (`janet/version`, `janet/build`, `janet/api`, `janet/config-bits`),
  docstrings and messages kept from the C implementation that are about the
  language or code written in it ("janet values", "a thread that is not
  running Janet"), and internal names about Janet values or mirroring
  `janet.h` (`JanetSignal`, `JANET_STREAM_*`).

Wattle has its own version, starting at 0.1.0. It is the package's and the
libraries' version, the version a module reports to the loader, and what
`wattle/version`, `wattle -v` and the REPL banner show. `janet/version` is the
version of Janet this runtime matches, currently 1.41.3, and `janet/build` is
`zig`. Both numbers are declared once, at the top of `build.zig`.

The environment variables, syspath, banner, versions, and those docstrings and
messages are the places where a Janet program can observe the difference. The
bindings, the docstrings and the command-line client's strings are part of the
core image, so the image differs from the C implementation's in those bytes.

The numbered sections fall into four groups. Sections 1 to 6 are about the
implementation of Janet 'values'. Sections 7 to 9 are about types and errors.
Sections 10 to 15 are about what a native module sees. Section 16 is about the
indexed protocol, through which an abstract type is read where an array or a
tuple is.

## 1. Value representation

The primary representation of a _value_ in Janet is NaN-boxed. This runtime
keeps the C runtime's representation: one machine word, the type tag inside it,
doubles stored untagged. It is the same eight bytes and the same bit patterns
rather than a redesign. Section 5 keeps the tagged layout for testing rather
than as the default representation.

The representation is called `Value`. The C runtime's convention names the type
after the language, `Janet`. This reads acceptably in C but poorly in Zig, where
the type is reached through its module (conventionally called `wattle`).

The representation is in a module named `repr`, so the type is `repr.Value`.

### Why a union at all

A dynamically typed language has to make every value state its own type. Boxing
everything behind a pointer makes that uniform and costs an allocation and a
dereference per number, which is fatal for numeric work. Tagging the machine
word itself puts small values (i.e. numbers, nil and booleans) entirely in the
machine word, and a pointer in the payload for everything else.

Once the tag lives in the machine word, by-value follows: the machine word is
pointer-sized, so a `callconv(.c)` signature passes it in one register; a
fiber's stack becomes a flat `[]Value` the collector walks linearly,
with no interior pointers; and assignment copies a machine word.

The union is not a variant record: it is a type-punning device. The same eight
bytes must be read as an `f64` for the NaN test, as a `u64` for tag extraction
and hashing, and as a pointer for the payload.

### The constraint that forces NaN boxing

A full-width `f64` plus a tag does not fit in 64 bits in any language. The
double uses every bit. NaN boxing is not an inherited C idiom: it is the only
way to have free doubles in a machine word. (The alternative, a native Zig
`union(enum)`, measures 16 bytes (i.e. two machine words), the same as the C
implementation's tagged fallback.)

The bit budget this runtime keeps, unchanged from `janet.h`:

| bits  | width | contents                                                     |
| ----- | ----: | ------------------------------------------------------------ |
| 51–63 |    13 | the NaN marker: sign + 11 exponent bits + quiet bit, all set |
| 47–50 |     4 | the type tag                                                 |
| 0–46  |    47 | payload: pointer (possibly alignment-shifted) or integer     |

If the double is not NaN, it is a number, stored as-is. As a result, the common
numeric case costs nothing.

Four tag bits means sixteen primitive types. The type system itself is not
capped: an abstract is one tag whose real type lives in its header, so the four
bits limit how many types get the fast path rather than how many can exist.
`int/s64` and `int/u64` are abstracts for this reason: the tag space is full,
and a 64-bit integer cannot fit in a double.

## 2. The type tag

The tag is an `enum` rather than a `u4`. The representation is identical; the
spelling is not. `repr.Tag` has the sixteen values, asserted at comptime against
`janet.h`'s numbering.

```zig
const Tag = enum(u4) { number, nil, boolean, fiber, string, symbol, keyword,
                       array, tuple, table, @"struct", buffer, function,
                       cfunction, abstract, pointer };
```

The order is the same as in `janet.h` (e.g. `JANET_FIBER` is at 3).

The type is `Tag` rather than `Type`: `Type` is the C name with its prefix
stripped (this implementation removes the 'Janet' prefixes used in C) but no
call site could spell `Type` comfortably given `type` is a reserved word in Zig.

Under nanbox-64, `Value` is an `extern union` of `u64`, `i64`, `f64` and a
pointer; under nanbox-32 it is an `extern union` of `Nanbox32Tagged`, `f64` and
`u64`, and under tagged it is an `extern struct` of a `TaggedPayload` and a tag.
`extern` fixes the field layout. The compiler checks that in two places: a
`Value` crosses `callconv(.c)` signatures by value, and a `Value` is stored by
value inside other `extern` layouts, `KV` and `Fiber` among them. In a third
place the layout matters and the compiler does not check it: code reads the
eight bytes directly, through `@sizeOf` and `std.mem.zeroes`. The inventory of
the layouts fixed this way is `res/check/layouts.txt`, and it records all
three against `Value` as `abi,field,repr`.

The alternative worth naming is a `packed struct`. Section 1's bit budget reads
as a field list, 13 bits of NaN marker over 4 of tag over 47 of payload, and a
`packed struct` would declare those three widths and have the compiler check
them. Three things rule it out.

The first is punning. An accessor reads the same eight bytes under more than
one type: as an `f64` to run the NaN test, as a `u64` to shift the tag out, as
a pointer to recover the payload. `nanbox64.typeOf` does the first two in a
single expression:

```zig
inline fn typeOf(x: Value) Tag {
    return if (std.math.isNan(x.number))
        @enumFromInt((x.u64 >> 47) & 0xF)
    else
        .number;
}
```

Writing one member of an `extern union` and reading a different one is defined
in Zig, so those two reads are spelled `x.number` and `x.u64` and no accessor
spells a cast. `toPointer` and `fromPointer` pun the same way between `u64` and
the pointer member.

The second follows from the first. A `packed struct` has a single backing
integer, so reading the word as an `f64` is a `@bitCast`, written out at every
site that runs the NaN test. The `extern union` needs none of them.

The third is a limit rather than a matter of noise. Two of `Value`'s three arms
hold an `extern` aggregate as a member: `nanbox_32` holds `Nanbox32Tagged`, an
`extern struct`, and `tagged` holds `TaggedPayload`, an `extern union`. A
`packed struct` cannot contain either, and the compiler rejects both the same
way:

`error: packed structs cannot contain fields of type '...'`

For two of the three arms the choice is therefore not available at all.

What the `extern union` gives up is the declaration. It names four overlapping
views of eight bytes, and nothing in it records which bits mean what. The bit
budget in section 1 is therefore the representation: the type fixes the size
and the overlap, and the table fixes the meaning of the bits.

The enum spelling improves over the C implementation at no cost. It is still
eight bytes and is bit-identical to `janet.h` (`repr.wrapNil` comes out
`0xFFF8800000000000` from both spellings; verified against `(JANET_NIL |
0x1FFF0) << 47`). However, it has the following benefits:

- Exhaustive `switch`. Omitting a case is a compile error naming the value:
  `note: unhandled enumeration value: 'pointer'`. The C macro chain cannot
  diagnose this.
- Better codegen. A sixteen-way switch compiles to a branchless test against a
  constant membership bitmask.

### What the tagged union does not provide

Exhaustiveness comes from the tag enum alone. What a `union(enum)` adds is the
`switch` capture: a prong can bind the payload it matched, as in
`.string => |s|`, rather than read it out of the word. There is still one
payload. This capturing is the extent of the benefit; the cost is an additional
eight bytes.

A hybrid, storing the packed machine word and exposing an
`inline fn view() Union` so call sites get `switch` with capture, was measured,
and the view does not optimise away. In `ReleaseFast` the view version set up a
frame and spilled to the stack, where the hand-written bit version stayed in
registers throughout. Future revisions should treat 'the view is
free' as false unless re-measured on a specific hot path.

## 3. Heads and payloads

Strings, tuples and structs are one allocation holding a header and a payload,
and the value this runtime passes around is the address of the payload, with
the header recovered by subtracting a fixed offset. Other heap-allocated values
hold the start of the allocation instead. This is the same approach taken by
the C implementation.

The split is not an inconsistency to tidy. Nothing about a raw payload requires
a value to point at it: a head-pointing string would keep its bytes just as
contiguous and just as NUL-terminated, and would trade a subtract on header
access for an add on payload access. The layout is copied from `janet.h`
rather than intrinsic to strings, which is why it falls out of the type
aliases:

| alias                         | type                  | names        |
| ----------------------------- | --------------------- | ------------ |
| `String`, `Symbol`, `Keyword` | `[*:0]const u8`       | the bytes    |
| `Tuple`                       | `[*]const repr.Value` | the elements |
| `Struct`                      | `[*]const tables.KV`  | the pairs    |
| `Abstract`                    | `*anyopaque`          | the data     |

### The payload offset

The payload offset is `@offsetOf(Head, "_data")`, exact per target and reported
by the compiler that laid the struct out. The allocator and the accessors read
the same constant. In C the same design costs an assumption, `sizeof(Head) ==
offsetof(Head, data)`; here it is a construction rather than an agreement. Where
the two spellings can diverge, meaning a head whose last declared field leaves
padding before a more strictly aligned element, the offset is right and the size
is wrong. Each head owns its offset and the accessor that subtracts it:
`strings.string_payload`, `tuples.tuple_payload`, `structs.struct_payload` and
`abi.abstract_payload`.

### The six flexible-array carriers

A _carrier_ is a struct whose last field is a `[0]T`, so the payload begins at
the end of the struct's own allocation. There are six of them rather than four.
Four of them point at their payload: the string, tuple, struct and abstract
heads. Two more are easy to miss because the value points at the head rather
than the payload: `Function`, whose `function_envs` is `@offsetOf(_envs)` and
whose block `gcallocWithPayload` sizes from `@sizeOf(Function)`, and
`ScratchBlock`, which reaches its payload through a `mem()` method rather than
a named offset.

All six must stay `extern`. This is because Zig's automatic layout may reorder
fields and a zero-sized member has no size to anchor it. If `_data` or `_envs`
were moved off the end, `@offsetOf` would report the new position and the
payload would be written over a header field. `extern` fixes this declaration
order.

### What Zig adds

The invariants move into the types, where a mistake is a compile error rather
than a convention:

```zig
/// A string is the address of its NUL-terminated bytes; the head is behind it.
pub const String = [*:0]const u8;
pub const Tuple  = [*]const Value;
pub const Struct = [*]const KV;
```

`[*:0]const u8` states the NUL-termination that C's `const uint8_t *` only
implies: `std.mem.span` works, slicing is checked, and a buffer that is not
terminated cannot be passed where a `String` is required. The offset is
declared once per head:

```zig
pub const string_payload = @offsetOf(StringHead, "_data");
```

`std.mem.alignForward(usize, @sizeOf(Head), @alignOf(Elem))` is not needed while
the head keeps its zero-length `_data` field: `@offsetOf` reports where the
compiler put the payload rather than deriving where it ought to go.

That call is needed again if `_data` goes. A hand-written Zig head has no need
to declare a zero-length array, and `@offsetOf(Head, "_data")` names a field:
delete `_data` and the expression no longer compiles, so the offset goes back
to being computed by `alignForward` rather than reported by the compiler.
Keeping `_data` is what secures the exact offset.

### The header's flag word and refcount

The flag word's bit positions and the refcount's width are agreed rather than
inferred. `abi.zig` declares `GCObject`, `GCFlags` and `GCData` because
`AbstractHead` opens with the garbage collector's header, and a native module
is compiled separately from the runtime. Declaring the header inside the
runtime would leave a module to declare its own copy, and two copies can drift
apart. Both compilations compile `abi.zig` instead, so there is one
declaration.

The flag word is `int32_t` in the C original. The width is one declaration and
the position of each named bit is another: in Zig the positions come from the
field order of a `packed struct`, so a reorder moves them while the width
stands. Each named bit has to sit where the C original put it, because a
tuple's `own` field leaves the process: `marsh.zig` writes it into the stream
and ORs it back on the way in, and the core image is a marshalled stream. Five
types use `own` in memory, and a tuple is the only type whose bits are also a
data format. So a bit that moved would be a wrong result from a working program
rather than a build failure. The assertions beside `GCFlags` compare it against
a mask table rather than against a second declaration. A mirror declaration
would be reordered along with the first and still pass; `0x100` for `reachable`
and `0x3F0000` for `own` state the positions independently, so a reorder fails
the build.

The refcount's width is determined by the platform. Windows'
`InterlockedIncrement` takes a `LONG`, so `abi.AtomicInt` is `c_long` there and
`i32` everywhere else. It fixes the size of `GCData`, and with it the offset of
`AbstractHead.type`, which is the field `abstract_type.ofAbstract` reads to
start a dispatch.

## 4. Head visibility

The string, tuple and struct heads of section 3 are internal: nothing outside
the runtime depends on their layout, and neither do the `Table`, `Array` and
`Buffer` structs. A native module reads these values through three functions in
`module.zig`. `wattle.bytesView` returns a slice of a string's, symbol's,
keyword's, buffer's or byte-like abstract's bytes, `wattle.toIndexed` an
`Indexed` over an array's, tuple's or indexed abstract's elements, and
`wattle.dictionaryView` an iterator over a table's or struct's buckets. Each is
one call through the module table and each uses the value's own storage rather
than a copy. An indexed abstract's elements take one further call per run.

The abstract head is the exception. `wattle.toAbstract` is compiled into a
module that defines an abstract type, and the function must read the head's
`type` field to check that a particular value is an abstract of that type. So
`AbstractHead` is declared in `abi.zig`, which the runtime and every module
compile. The runtime and module share one declaration rather than each keeping
a copy (section 3).

In contrast, the header in the C implementation (`janet.h`) makes the heads
public intentionally. From `janet.h` (emphasis added):

> Some janet types use offset tricks to make operations easier in C. **For
> external bindings**, we should prefer using the Head structs directly, and
> use the host language to add sugar around the manipulation of the Janet
> types.

The consumers are the authors of bindings in another language, such as Rust or
Python, who want to walk Janet values without going through the C API. The Zig
runtime has no C API (section 10) and a native module is written in Zig and
reads values through those three functions.

With the heads internal and the layout owned by Zig, there is nothing for a C
file to assert about them. Consequently, `test/` in this implementation has no
`.c` files.

## 5. Value layouts

This runtime has three value layouts: nanbox-64 (the default on x86-64, aarch64
and riscv64); nanbox-32 (the default on a 32-bit target); and tagged (the
default on every other 64-bit architecture, and selectable using
`-Dnanbox=false`). `-Dnanbox=true` selects NaN boxing on any target.

### Why tagged is kept

In the C implementation, the tagged layout is the fallback for architectures
where NaN boxing is unsafe. A 64-bit NaN-boxed value holds a pointer in 47 bits,
so `janet.h` enables NaN boxing by default only for 32-bit builds and for 64-bit
x86, RISC-V and ARM, and gives every other architecture the tagged layout. No
target in scope needs that fallback: x86-64 and arm64 macOS keep user-space
addresses within 47 bits, arm64 Linux gains two bits from a default pointer
shift of 2, and a 32-bit target uses nanbox-32.

It is kept for testing. `res/testing/matrix.janet` runs the contracts under it
as well as under nanbox-64. The two layouts store a value differently but must
behave the same, so a contract that passes under nanbox-64 and fails under
tagged points at code that reads a value's bits directly instead of going
through the accessors.

### Why nanbox-32 is kept

The nanbox-32 layout is what a 32-bit target gets: `build.zig` selects it
whenever `-Dnanbox` is on and the target's pointers are 32 bits wide.
`wasm32-wasi` is such a target: `res/testing/matrix.janet` runs the suites
and contracts on it under wasmtime. The other supported platforms are macOS and
Linux on 64-bit, with Windows build-only. Keeping that arm has a cost: it is a
third comptime arm that every change to the value representation must be
written against.

## 6. Numbers

There is one number type and it is a double. This runtime follows the C runtime:
a number is a `f64`, stored inline, and there is no separate inline integer. The
alternative is an inline integer type, a fixnum. A fixnum with a useful range
would mean replacing NaN boxing with a representation that heap-allocates every
double, and the subsections below explain why that trade is rejected.

### What was on the table

A _fixnum_ is an integer held directly in the value's machine word rather than
as a pointer to a heap object. Because Janet's only number is a double, exact
whole numbers run out at 2^53. As a result, 64-bit integers have to arrive as
the abstract types `int/s64` and `int/u64`. Those are `AbstractType`s, so every
64-bit integer is a heap allocation and every arithmetic result is yet another.

### Why there is no small fixnum

Spending one of the sixteen tags on a fixnum gains nothing, and the reason is
the bit budget in section 1. A NaN-boxed payload is 47 bits. A double already
represents whole numbers exactly to 2^53. So an inline fixnum inside a
NaN-boxed value would represent a smaller range than the representation it was
meant to improve.

Getting fixnums therefore means abandoning NaN boxing altogether for low-bit
pointer tagging: put the tag in the three bits every 8-byte-aligned address
wastes, leave about 61 bits for an inline integer, and box doubles instead.

### Why the trade is the wrong way round for this runtime

|                    | NaN boxing (kept) | low-bit tagging |
| ------------------ | ----------------- | --------------- |
| float arithmetic   | free              | allocates       |
| integers to 2^53   | free              | free            |
| integers past 2^53 | allocates         | free            |

The allocation is moved rather than removed, and it is moved onto the common
case. In Janet every plain number is a double, so 'doubles allocate' does not
mean float-heavy code slows down. Having both inline does not fit in 64 bits.

### The escape hatch, and why it is closed

The remaining option is to give the language a real integer type, so integers
take the inline slot and floats box only where floats are used. The result is a
different language: `(= 1 1.0)` stops being true and `(/ 1 2)` plausibly stops
being `0.5`.

### What would reopen the decision

If this runtime's workload turned out to be integer-dominated, and if breaking
the behavioural expectations of Janet source were considered acceptable, this
decision could be reconsidered. However, the cost would be significant. A
change would mean rewriting marshalling, hashing and comparison, all of which
are built on the current representation.

## 7. Pointer types

The port inherited its types from translate-c, which renders every C pointer `T
*` as `[*c]T`. A `[*c]T` may be null, may point at one item or at many, carries
no length, and converts implicitly to and from other pointer types. As a
result, the compiler checks none of those properties.

This runtime replaces each inherited type with a precise one: `*T` for a pointer
that is never null, `?*T` where null is a state the code tests, `[]T` where the
length travels with the pointer, `[*]T` where the count is stored elsewhere, and
`[*:0]const u8` for a NUL-terminated string. The compiler then checks those
properties at every use site.

### Scope

Three other sections apply this decision to one type family each: section 2
makes the tag an `enum(u4)` rather than a `c_int`, section 3 makes `String`,
`Tuple` and `Struct` state their termination and element, and section 12 makes
an abstract type's name a slice and its callbacks take a typed payload.

### Conventions

A `[*c]` belongs only where a C signature fixes the type: (1) `abi.CFunction`,
the C ABI's shape for a stored cfunction pointer, and (2) the libc declarations
`cabi.zig` reaches through `@cImport`. Anywhere else it is an unfinished
replacement.

#### Why a slice cannot cross

`export fn` forces the C calling convention, and a slice has no guaranteed
in-memory representation, so Zig refuses one in any `callconv(.c)` signature or
`extern struct`:

    error: parameter of type '[]const u8' not allowed in function with
    calling convention '<target's C convention>'
    note: slices have no guaranteed in-memory representation

So a slice crosses the module table as a pointer and a length. The module
passes a slice's `.ptr` and `.len`, and `capi.zig` rebuilds it with
`ptr[0..len]`. The pointer is a non-optional `[*]const T` and the length a
`usize`, so neither a null pointer nor a negative count can arrive.

#### One rule each

- `argv`, and every value array with a count beside it, becomes `[]Value` or
  `[]const Value`. `raise.CFunction` uses Zig's calling convention rather than
  C's: the stored slot is cast to it with `@ptrCast` and no thunk, so both sides
  are Zig and a slice is legal.
- The tuple and struct payloads become `[*]const Value` and `[*]const KV`. As
  in section 3, the value is the payload address, and the count lives in the
  head behind it.
- A C string, meaning a name, a docstring, a path, a message or a literal,
  becomes `[*:0]const u8` where the NUL is known to be there (see 'When a
  sentinel is claimed'). The NUL is the only terminator there is, and
  `std.mem.span` recovers the length where a caller needs it.
- A byte range that already has its length beside it becomes `[]const u8`, so
  the pointer and its length are passed as one value.
- A pointer to a runtime struct, meaning `Fiber`, `Table`, `Buffer`, `FuncDef`,
  `Function`, `Array`, `FuncEnv` or `MarshalState`, becomes `*T`, or `?*T` where
  absence is a state the code tests. 'Which pointers are optional' below says
  which.
- C's growable vector, `janet_v`, whose count lives in a header behind the
  pointer, becomes `scratch_vector.Vector(T)`, a `std.ArrayListUnmanaged(T)`
  over the scratch allocator.
- An out-parameter becomes `*T`, or `?*T` where a caller may pass null to
  discard the result, as with `dobytes`, `dobytesImpl` and `dostring`.

Outside a `callconv(.c)` signature, a `[*]` where a slice was available is an
unfinished replacement.

#### When a sentinel is claimed

A pointer gets the type `[*:0]const u8` only where something shows the NUL is
there. `[*c]const u8` and `[*:0]const u8` coerce to each other with no check of
the NUL, so a wrong sentinel is neither a compile error nor a run-time one.

There are two 'somethings' that can show it. Either the code reads the NUL (by
passing the pointer to `std.mem.span`, `std.mem.len`, `strlen` or a function
whose parameter is already `[*:0]`) or the allocator writes it (as the Janet
string constructors do, see 'Where a sentinel is created' below). A byte
pointer with neither is `[*]const u8`: not null, no length and no claim about
termination.

#### Where a guarantee lives

The conventions apply to a struct's fields as well as to function parameters: a
pointer to one object is `*T` or `?*T`, a C string is `[*:0]const u8`, and a
pointer to many is `[*]T`. A parameter typed `*T` is only as reliable as the
field its argument is loaded from. A `[*c]` field coerces to `*T` with a
run-time check rather than a compile-time one, so a null stored in the field
still reaches a parameter typed `*T`.

The one convention a field cannot always follow is the slice. A slice has no C
ABI representation, so wherever one crosses a `callconv(.c)` signature it is
split into a many-item pointer and a `usize` length. As parameters, the pair
keeps the slice's guarantee: a slice's pointer is never null. As fields, it
does not. The views in `api/abi.zig` are `extern struct`s that carry a pointer
and a length back across the module table, and the pointer is optional because
there may be nothing to point at: an empty array has no storage.

Rebuilding a slice from a view therefore maps a null pointer to the empty
slice rather than unwrapping it with `.?`, since slicing a null pointer traps
even for an empty range. The runtime does this in `viewBytes` in
`runtime/args.zig`, and `module.zig` does it inline in `bytesView` and
`getBytes`, and in `indexedOf`, which `getIndexed` and `toIndexed` share:

```zig
pub inline fn viewBytes(view: abi.ByteView) []const u8 {
    if (view.bytes) |p| return p[0..view.len];
    return &.{};
}
```

A `DictView` is not rebuilt into a slice. Its storage is sparse, so
`module.zig` walks it with `Pairs`.

#### Where a sentinel is created

The subsection 'When a sentinel is claimed' above says where a `[*:0]` may be
written. This subsection says where the NUL is created.

Four stores write the NUL: `strings.new` and `strings.begin` in
`runtime/value/strings.zig`, and `intern` and `gen` in
`runtime/value/symbols.zig`. Each allocates room for a NUL after the bytes,
writes it, and returns the payload as `[*:0]const u8`, except `begin`, which
returns the unfinished string as `[*]u8` for `strings.end` to close. Those
stores are the only reason a Janet string is NUL-terminated, and the sentinel
type is written beside each:

```zig
payload[buf.len] = 0;
return @ptrCast(payload);
```

`strings.String`, `strings.Symbol` and `strings.Keyword` are `[*:0]const u8` for
that reason, and so is the parameter of every function that takes one, such as
`wrap.fromString`.

#### An empty collection's data pointer

Each collection type declares its element pointer optional: `data` is `?[*]T`
in `Array`, `Buffer` and `Table`, and it is null in a zeroed struct of each.
The point at which each of these live collections has a null `data` differs:

- An array's is null at capacity zero. `arrays.zig`'s `init` leaves it null and
  the first push allocates.
- A buffer's is never null after `init`, which allocates at least four bytes.
  `deinit` sets it back to null, and a foreign buffer made by `pointerUnsafe`
  holds whatever pointer it was given, null included.
- A table's is never null after `init`, which allocates at least one bucket.

Each type's accessor, `Array.slice`, `Buffer.slice` and `Table.slots`, returns
an empty slice when the count or capacity is zero rather than unwrapping `data`
with `.?`.

`.?` at a use site is a claim that the length is non-zero, not only that the
pointer is set. Inside `while (i < count)` it is safe, because the loop body
cannot run at count zero. In `p.?[0..count]` it is a bug: the expression is
reachable at count zero, and it panics there. Both spellings compile, so the
difference shows only when the empty case runs.

#### Which pointers are optional

A pointer is `?*T` where the code stores or tests a null, and `*T` everywhere
else. `Vm`'s `fiber`, `root_fiber`, `top_dyns` and `return_reg` are tested for
null, as in `if (v.fiber) |fiber|`, and so is a fiber's `child` link. Two fields
that look permanent are optional for the same reason: `deinitCompiler` sets
`Compiler.env` to null, and a function is allocated and marked reachable before
it is given its definition, so `Function.def` is null until then, as the comment
in `gc/mark.zig` says.

Every pointer field of `Vm` is optional regardless: `vm/state.zig` declares `vm`
as `std.mem.zeroes(Vm)`, and a non-optional pointer cannot be zeroed.

#### What a remaining `[*c]` means

The design of the Zig implementation does not require the use of `[*c]`. `*T`,
`?*T`, `[*]T`, `?[*]T` and `[*:0]const u8` are each one machine word, and each
is legal in a `callconv(.c)` signature and in an `extern struct`. What the
calling convention refuses is a slice ('Why a slice cannot cross'), not a
precise pointer. A `[*c]` that remains is a type nobody has replaced yet,
not one the boundary requires.

#### The exception

One remains: `abi.CFunction`, the C-ABI shape in which a cfunction pointer is
stored (`Reg.cfun`, `CMethod.cfun`). Its `argv` is `[*c]Value`.
`raise.cfunction` casts it back to the Zig-convention `raise.CFunction` before
any call.

Callback types that only this tree implements, such as the parser's `Consumer`
and `callback_type.zig`'s `EVCallback`, follow the conventions like any other
type.

One `[*c]` is not the tree's own: libc declares `getaddrinfo`'s result
parameter as `[*c][*c]struct_addrinfo`. `net.zig` holds the result as
`?*h.struct_addrinfo`, a nullable linked-list head, and passes its address.

### What a raw pointer still means afterwards

A pointer without a length still arrives in three places, and the length is
recovered where it is used:

- A C library returns one. `realpath(3)` allocates a buffer and returns its
  address, with no length (`os/fs.zig`).
- A struct that crosses the module table holds one. `Reg`'s `name`,
  `documentation` and `source_file` are `?[*:0]const u8`, because `Reg` is
  `extern` and cannot hold a slice.
- An FFI call returns one, and the pointer is foreign.

## 8. Raising errors

As the introduction says, one of the reasons to attempt this implementation was
to see whether Janet could be written without `setjmp` and `longjmp`. It can:
no configuration compiles `setjmp`, `longjmp` or a `jmp_buf`. A raise-capable
function instead has the return type `raise.Error!T`: it either returns a `T`
or returns an `Error`. Every call site handles the result, usually with `try`,
and a raise reaches its scope as an ordinary return through each frame in
between.

In contrast, the C implementation raises errors using `longjmp`: `janet_panic`
jumps to the `jmp_buf` that the nearest `janet_try` filled with `setjmp`, past
every frame between the two.

The signal, the payload and the trace a Janet program observes are unchanged;
only the way the implementation carries them differs.

### Where the value and the signal go

`Error` has one member, `error.JanetSignal`, because a Zig error carries no
payload. Both halves of a raise are stored on the VM instead:
`signal.signalRecord` writes the value to the return register and the signal to
`pending_signal`, and the raising function then returns `error.JanetSignal`.

A try scope is `signal.tryInit` and `signal.restore` with the call between
them. `tryInit` points the return register at the scope's payload, which is
what makes a raise catchable; in C, `setjmp` was the transfer rather than the
scope. Resuming a fiber is the scope the interpreter runs under:

```zig
signal_core.tryInit(&tstate);
// ...
const sig = vm_run.runVm(fiber, in) catch vm.pending_signal;
// ...
signal_core.restore(&tstate);
```

Nothing inside the interpreter loop catches a raise. When something the loop
calls raises, such as a cfunction, a table access or a comparison, `runVm`
passes the error up with `try`, and it stops at the `catch` above, one frame up
in `continueNoCheck`. As in C, there is one scope per resume rather than one per
call.

### What returning buys

A returned error unwinds frame by frame, so `defer` and `errdefer` run on the
way out and are legal everywhere. A `longjmp` would pass over the frames
between the raise and the scope without running anything in them, including
their `defer` and `errdefer` blocks (breaking the expectation of a Zig
programmer that these run whenever the relevant scope is left).

Whether a function can raise is in its signature. A function whose return type
has no error union cannot raise, and a `try` inside it does not compile. The six
non-raising callbacks in section 12 are that rule applied to an author's code.
Where there is no caller that could take a raise, as in a collector traversal,
a finalizer, a teardown or a thread's entry point, the raise-capable call is
wrapped in `raise.total`, which aborts if the call raised.

### Across a `callconv(.c)` crossing

A native module calls the runtime through the module table, a table of function
pointers (`api/interface.zig`'s `Runtime`) that the runtime passes to the
module's `_wattle_init`. Each field of that table is a _crossing_: one runtime
function a module may call. Because a module and the runtime are compiled
separately, every crossing uses the C calling convention (which is documented
rather than tied to a Zig version, see section 10). Zig gives an error union no
guaranteed representation, and so one is not allowed in the signature of a
`callconv(.c)` function. As a result, a raise crosses on a flag instead. On the
runtime's side, `raise.toAbi` records the raise and returns a zeroed value.
On the module's side, `raise.fromAbi` wraps the call, tests the flag and
returns `error.JanetSignal` again. A flag still set when a try scope closes is
fatal, so a missed test is found within one scope of the call that missed it.

A cfunction and an abstract type's raising callbacks cross the other way, from
the runtime into a module, and return an error union over Zig's own calling
convention. No C body can have that type, which is why a native module is
written in Zig and why the module and the runtime must be built with the same
Zig version, for the same target (section 10).

### What it costs

A `longjmp` reaches its scope in one jump. A returned error passes through
every frame between the raise and the scope, and every raise-capable call site
tests the result on the way, whether or not anything raised. Zig also returns
an error union with a non-`void` payload through memory: an out-of-line call
returning `raise.Error!Value` has its result stored to and reloaded from the
caller's stack, where a plain `Value` or a `raise.Error!void` comes back in a
register. An inlined call has no return to pay for.

On a recursive hot path the memory return is a measurable cost, and the
signature keeps it. There are two ways around it, and both were rejected. A
raise carried on a flag, with a plain return type, would make the property in
'What returning buys' false for every function that used it. Returning
`raise.Error!void` and storing the result elsewhere gets the return into a
register, but the result is still stored to and reloaded from memory, and it
measured no faster than the memory return.

## 9. Signal numbers

An out-of-vocabulary signal number is clamped rather than passed through, which
is a deliberate change from the C implementation.

In both implementations, a signal is one of fourteen named values. In C, this is
an `enum`, and a C `enum` is just an `int`. As a result, any integer is a valid
`JanetSignal`. In Zig, `abi.Signal` is an exhaustive `enum(c_uint)`. While this
is 32 bits wide, only the fourteen members are valid `abi.Signal` values.
Converting any other number with `@enumFromInt` is illegal behaviour at the
conversion itself, not later at a `switch` that has no case for it.

In C, the number is reachable from outside through `janet_continue_signal`,
which stores its signal argument in six bits of the target fiber's GC header.
`run_vm` reads those bits back and returns them, so a C caller could pass 42
and get 42 back. In Zig, `signal.signalInject` makes the same store and `runVm`
reads the bits back with `@enumFromInt` into an exhaustive enum, so an
out-of-range number there is illegal behaviour: it traps in a safe build and is
undefined in a fast one.

Three options were available: keep the domain by passing a raw integer through
every signal-returning path, make `Signal` non-exhaustive, or decide what an
out-of-vocabulary number means. The first un-types six return paths to preserve
a value nothing consumes; the second gives up the exhaustive `switch` that is
most of what the semantic type is for.

So the number is clamped, and the rule is Janet's own. `JOP_SIGNAL` takes a raw
number out of an instruction field and does this:

```c
if (s > JANET_SIGNAL_USER9) s = JANET_SIGNAL_USER9;
if (s < 0) s = 0;
```

`abi.Signal.fromWire` applies that clamp's upper bound; it takes a `c_uint`, so
there is no negative case. A raw number enters in two places, and both convert
it with `fromWire` before it becomes an `abi.Signal`: `runVm`'s arm for the
signal instruction, which first maps a negative field to 0, and `capi.zig`'s
`wattle_signal_record`, which implements a module's `signal_record`
crossing. `signalInject` takes an `abi.Signal`, so the read-back
in `vm.zig` is in range because only a member can reach those bits.

What is given up is the round trip: an injected 42 returns `user9` rather than
42. No caller in Janet or in this tree consumes an out-of-vocabulary signal, and
what it replaces is undefined behaviour rather than a behaviour.
`test/signal_core.zig` pins both ends.

`abi.zig` follows the numbering used in the C implementation. As a result, both
vocabularies take their values from `janet.h`: `Signal`'s fourteen and
`FiberStatus`'s sixteen, each with a comptime table over the whole population
beside the enum (similar to section 2's `repr.Tag`). A fiber's status travels
in a marshalled fiber, where `marsh.zig` writes the whole flag word and
validates only the stored number's range on the way in, so a member renumbered
without its row would misread every image already written.

## 10. Public interface

The public interface is the Zig module interface. A native module is written in
Zig and compiled to a shared object, which the Zig implementation loads in the
same way that the C implementation loads native modules written in C.

This runtime aims to preserve behaviour identity with the C runtime, within the
limits the Introduction sets. A program written in Janet should work the same
way with the same error messages, signal kinds, traces, marshalled bytes,
bytecode and the core image. It does not preserve an identical C symbol table.

The runtime exports no symbols. A module exports two (`_wattle_mod_config` and
`_wattle_init`) but the author is not expected to write either directly. Rather,
the module author uses `wattle.entry`, a comptime function that generates and
exports the symbols. The runtime's loader looks both up by name when it opens
the shared object: `_wattle_mod_config` reports what the module was built
against (Wattle's version, the configuration bits, the Zig version and the
interface fingerprint), and `_wattle_init` receives the module table (every call
a module makes into the runtime goes through one of the table's 81 crossings).

With nothing exported, every program built using this implementation reaches
the runtime by `@import`: the client, the image generator and the contracts
each import it as the `subsystems` module with calls within the runtime being
ordinary Zig calls. `capi.zig` holds the runtime's side of the module table
and exports nothing. `cabi.zig` declares only what is external to Janet: libc
and the Windows API.

A native module is still a separate compilation, so `module.zig` is a real
boundary. Calls into a module use Zig's own calling convention (section 8),
which is deterministic for a Zig version and target but not documented. A
module must therefore be built with the same Zig version, for the same target,
and with the same configuration as the runtime into which it loads
(`examples/numarray/README.md`). The loader checks the configuration bits, the
Zig version and the interface fingerprint that `_wattle_mod_config` reports, and
refuses the module on the first difference. `build.zig`'s `wattleModule` helper
builds a module with the options given to its `wattle` dependency, and
`examples/standalone` shows that build working from outside the tree.

### Linking a module in

A module can also be linked into an executable, with the runtime and an image of
a Janet program, so that one file cross-compiles and runs with nothing beside
it. `build.zig`'s `quickbin` builds such an executable, `examples/quickbin` is
the worked example and `examples/standalone` builds one from outside the tree.
The decision has three parts, and each keeps something above unchanged.

The module's source is unchanged. `wattle.entry` still generates the two
symbols; under a build setting that names the module it exports them as
`_wattle_init_<name>` and `_wattle_mod_config_<name>` instead, because two modules
in one binary cannot both export the plain pair. Each module is compiled as an
object of its own rather than into the executable's compilation, so
`interface.rt` stays one variable per module, as it is for a loaded one. The
executable calls the entry point with the same module table a loaded module is
given, and runs the same three checks first. In a static link they cannot
fail, and the module is not told which way it was built.

The image names the module rather than containing it. A cfunction has no wire
form: `marshal` writes one only as a name its dictionary maps the value to, and
`unmarshal` reads a name only through its dictionary. `module/add-native` is
the one registration both sides perform, under a name the build chooses: it
puts the module's environment in `module/cache` under that name, so `(import
name)` resolves without a path, and adds `name/<binding>` for each cfunction
and abstract to `make-image-dict` and `load-image-dict`. The client that makes
the image registers the module loaded as a shared object; the executable
registers the module linked in; the name is the contract between them.
`run-image` is the other half: given the image, the arguments and a loader per
module, it registers each module, loads the image and runs `main`. `wattle -i`
calls it too, so an image file and an executable are one path. This is what
`jpm quickbin` does with a generated C file, and the reason the executable is
not an embedding: the program inside it is data the runtime reads, and a `main`
the runtime runs.

The runtime stays private. The public build surface grows by one function and
not by the runtime module, because the executable is the unit an outside author
asks for. A public runtime module would be an embedding interface and it is not
needed for this: `quickbin` takes two instances of the `wattle` dependency, one
for the target and one for the build machine, because the image is made by
running a client and an image is architecture-neutral.

## 11. Built-in types

The C implementation defines the struct of every built-in type in `janet.h`,
from `JanetTable` to `JanetFiber`. `janet.h` is the public header, so a module
written in C sees each of those structs and can read their fields.

This implementation declares a built-in type in the file that implements it.
`Table` is in `value/tables.zig` and `Fiber` is in `value/fibers.zig`, and the
runtime's other files name each through its file, as `tables.Table`.

A few types have to be seen by a module as well. A module is compiled
separately from the runtime (section 10). When the runtime and the module need
to pass a value of some type between themselves, both compilations need the
same declaration of that type, so it is declared in a file both compile. That
makes three places a built-in type can be declared: `repr.zig` for the value
representation, `abi.zig` for the other types a module shares with the runtime,
and the type's own file for everything else.

`GCObject` is an example. The collector is implemented in `gc.zig`, but
`GCObject` is declared in `abi.zig`, because `AbstractHead`, the header in front
of an abstract's payload, includes it.

### The three places

1. `repr.zig`, the value representation. It declares `Value` (section 1),
   `Tag` (section 2), the three layouts (section 5), and the operations on a
   value that name no heap type: wrapping and unwrapping a number, a boolean or
   nil, reading the tag, and converting a pointer payload. `config.value_repr`
   selects the layout at compile time.

   Files under `api/`, `boot/`, `client/` and `runtime/` import `repr.zig`
   directly, `abi.zig` among them, and nothing in the tree sits below it. It
   imports only `std` and `config`. `build.zig` gives the `repr` module no other
   import, and Zig rejects an import by path from outside a module's directory,
   here `src/api/`. An import of the allocator, tables, the VM or the collector
   is a build error, so a module that compiles `repr.zig` compiles none of the
   runtime with it.

   A module compiles `repr.zig` against its own `config`, which `wattleModule`
   generates from the options given to the `wattle` dependency. A module built
   with the runtime's options selects the same layout, and the loader checks the
   configuration the module reports (section 10). A module uses `Value`, `Tag`
   and the operations that read only the bits: it reads a value's tag, and
   wraps and unwraps a number, nil or a boolean, without a crossing. A value
   that carries a pointer, and the integer range test, go through a crossing
   (section 13).

2. `abi.zig`, the boundary. It declares five kinds of type: the two views
   (`ByteView` and `DictView`) with `Indexed`, the six capabilities, the two
   enums (`Signal` and `FiberStatus`), the layouts a crossing takes or returns
   by pointer (`Reg`, `Range`, `BuildConfig`, `KV`, `CFunction`, and
   `AbstractHead` with the `GCObject` it begins with), and `AbstractType`. A
   module also reads `AbstractHead` without a crossing. `module.toAbstract`
   checks an abstract's type by reading the header's `type` field, so the offset
   of that field has to be the same in both compilations.

   A capability is `opaque {}` so that a module can neither read a field nor
   make a capability. In the runtime, the pointer is to a runtime struct: `Env`
   to a `tables.Table`, `Render` to a `buffers.Buffer`, `Marshal` and
   `Unmarshal` to `marsh.zig`'s `MarshalState` and `UnmarshalState`, and `Loop`
   and `Wake` to a `vm_state.Vm`. `runtime/capi.zig` and `runtime/marsh.zig`
   cast the pointer back, so the layouts of those structs are not part of what
   a module must agree on.

   `abi.zig` imports `repr` and nothing else of the tree's, and `build.zig`
   gives the `abi` module that one import. Section 14 gives the reason. A layout
   is added to `abi.zig` only when what crosses to a module changes.

3. The type's own file, for everything else. The file is part of the runtime
   module, whose root file is `src/root.zig`. A heap type's file is named for it
   under `runtime/value/`, from `abstracts.zig` to `tuples.zig`. Three
   placements do not follow the name. `String`, `Symbol` and `Keyword` are all
   declared in `strings.zig`, and `symbols.zig` holds the interning. `KV` is
   declared in `abi.zig` and aliased by `tables.zig`. A number, nil or a boolean
   is stored in the value itself and has no heap type, so `repr.zig` is its only
   file.

   Zig permits an import cycle between files whose declarations do not form a
   comptime loop, so two owner files that use each other's types import each
   other: `tables.zig` imports `structs.zig`, and `structs.zig` imports
   `tables.zig`.

### The module API on one page

In an attempt to make it easier for module authors, the module API is primarily
described in `module.zig`. The aim is for an author to be able to find all the
information they would reasonably need on this page. As a result, `Error`,
`CFunction`, `Spec` and `define` live in this file together with their bodies.

The erasure is in `api/abstract_type.zig`. `check`, `collect` and `Erased` turn
an author's literal into the runtime's vtable, and the runtime's own abstract
types are built by the same code. It is kept out of `module.zig` because an
author never needs to read it.

The runtime does not name the four declarations through `module.zig`. Rather,
`api/abstract_type.zig` re-exports `Spec` and `define`, `api/raise.zig`
re-exports `Error` and `CFunction`, and runtime code names them through those
two files. Six files in the runtime's compilation import `module.zig`:
`api/abstract_type.zig`, `api/fingerprint.zig`, `api/interface.zig`,
`api/raise.zig`, `runtime/capi.zig` and `runtime/method_type.zig`. What they
name from it is
resolved at compile time: three types (`CFunction`, `Method` and
`PostCallback`), an error set (`Error`), a type-returning function (`Spec`) and
a comptime function (`define`). Zig analyses only what is referenced, so no
function of `module.zig` that reads `interface.rt` is analysed in the runtime
and none is emitted.

### Checking the boundary

No tool checks what `abi.zig` contains. `res/check/orphans.janet` does not
report a declaration there that nothing in the tree references, because a
separately compiled module may be what uses it. The file's header lists the five
kinds of declaration it holds, and a reader checks the file against that list.

`examples/numarray` and `examples/standalone` prove the boundary set is
sufficient, because they are built the way an outside author builds.
`res/check/layouts.txt` lists every `extern` layout in the tree with the
evidence that fixes it, the layouts in `abi.zig` among them, and
`res/check/layouts.janet --check` fails when the tree no longer matches the
list. The cross-builds in `res/testing/matrix.janet` cover the platform
declarations, which are the ones a native build cannot check.

`theHeadOffsets` in `test/gc_mark.zig` checks the offset a module depends on,
`abi.abstract_payload`. It is `@offsetOf(AbstractHead, "_data")`, the distance
from the start of an abstract's allocation to its payload. The allocator adds
it, and `abi.abstractHead` subtracts it when `module.toAbstract` reads an
abstract's type. The test compares the allocator's result against
`@sizeOf(abi.AbstractHead)`, which is computed separately. Code in `src/` that
needs the offset reads `abi.abstract_payload`, so a change to `AbstractHead`
changes the offset in one place.

## 12. Modules: abstract types

An abstract type is where a native module's own data enters the runtime.
`AbstractType` is a name and fifteen callback slots. The slots it stores take
the payload as `*anyopaque`; the callbacks an author writes in the `define`
literal take it as `*T` (the C implementation has `void *` throughout). A
module author supplies the callbacks to a typed constructor, while the runtime
stores an erased vtable generated from them. The erasure is required rather
than inherited from C: every abstract's header holds the same `*const
AbstractType` field whatever the payload's type, and the sweep and the
unmarshaller call through that pointer with no `T` in scope. Everything else a
module touches is either a capability or reached through a function.

This section records three decisions about the shape of `AbstractType`: the type
of the payload a callback takes, which callbacks can raise, and the type of
`name`. The first two make a mistake in a module's callbacks a compile error in
the module.

### The typed payload a callback takes

The C signature type-erases every callback as `void *data, size_t len`, so an
author's first line is always an unchecked cast, in code the runtime cannot
diagnose. Transcribed into Zig, that callback begins:

```zig
fn numArrayGc(p: ?*anyopaque, len: usize) callconv(.c) c_int {
    const self: *NumArray = @ptrCast(@alignCast(p));   // nothing checks this
```

The Zig implementation instead provides `wattle.define`, a comptime constructor
that takes the payload type and generates the erased vtable:

```zig
const num_array_type = wattle.define(NumArray, .{
    .name = "numarray",
    .gc  = numArrayGc,      // fn (*NumArray, usize) void
    .get = numArrayGet,     // fn (*NumArray, Value) Error!?Value
    .put = numArrayPut,     // fn (*NumArray, Value, Value) Error!void
});
```

The runtime still keeps one erased `*const AbstractType` and dispatches through
it unchanged; what differs from the C implementation is that `define` wraps
each callback in a comptime shim that performs the cast once, correctly, in
code the author does not write. The cast does not disappear; it is merely
moved. (A raw `AbstractType` literal also compiles and runs, but is not
recommended. Its callbacks cast the erased payload themselves, with nothing
checking the cast, and a wrong raising contract or an unknown slot fails with
Zig's own type error rather than the message `define` gives.)

The typed callbacks keep the `len` parameter of the C signature: in the example
above it is the `usize` in `gc`'s signature, while `get` and `put` do not take
it. `len` is the size of the payload allocation, and `T` describes only its
fixed-size start. Most abstract types allocate exactly `@sizeOf(T)`, but four
in the runtime allocate more and store variable-length data after `T`:
`net.addressType` at the socket address's length, `pegType` at the size of its
bytecode and constants, `streamType` at a size its caller chooses, and
`ffi/types.zig`'s `struct_at` at a size its field count sets. `*T`
removes the cast without losing the length. A callback that ignores the
trailing data ignores `len`; a callback that walks it has the same information
as in C.

Every abstract type in the runtime is built by `define`, so a callback is
written over `*T` and the cast lives in one place. `compare` takes two
`*const T`, a strengthening C could not express: the runtime reaches that
callback only when both abstracts have this type.

### The seven callbacks that cannot raise

Seven callbacks cannot raise:

|             | callbacks                                                                  |
| ----------- | -------------------------------------------------------------------------- |
| non-raising | `gc`, `gcmark`, `gcperthread`, `compare`, `hash`, `bytes`, `chunk`         |
| raising     | `get`, `put`, `next`, `length`, `call`, `tostring`, `marshal`, `unmarshal` |

`compare` and `hash` are called from inside comparisons that must return a
result. `gc` and `gcmark` are non-raising by contract: a finalizer runs
mid-sweep on an object that is already unreachable and `gcmark` runs
mid-traversal, so there is no scope above either, no caller that could act on
an error, and nothing to retry. A raise from one of them has nowhere to go for
anybody, a native module included. `chunk` hands out a run of a payload's
elements that the reader holds while it reads, so it may neither raise,
allocate nor run Janet code, and the run cannot change under the reader.

What allowing it costs is measurable in C, where a panicking finalizer poisons
the heap: the block is finalized but neither freed nor unlinked, every later
sweep finalizes it again, and the deinit eventually exits the process. Typing
them non-raising makes that a compile error at the callback's own definition,
which is the only place the diagnosis is cheap. `gc` and `gcmark` return `void`
here, where the C original returns `int`.

### Names and the erased layout

`AbstractType`'s `name` field is a `[]const u8`, where the C implementation has
a `const char *`. The length is known, and no call site passes it where a C
string is required: `cfunType` builds a keyword from the bytes and `typestr`
returns the slice, so no NUL is needed. An `extern struct` cannot hold a slice,
so `AbstractType` is not `extern`. What `extern` bought in C was a layout a
separately compiled consumer could reconstruct from `janet.h`; here both
compilations read the declaration in `abi.zig`.

The erased vtable keeps the field order `janet.h` used, with `chunk`, which
`janet.h` does not have, after the last of them. Reordering gains nothing that
would justify changing every stored table. That said, the order is
an internal erased-layout decision rather than source API for a module author
(who uses the typed constructor).

### The compile errors a module gets

The wrong payload, a raising `gc`, a non-raising `get`, an unknown slot, a
`chunk` without a `length` and a wrongly shaped cfunction are each a compile
error naming the contract rather than diffing two function types.
`zig build module-errors` can be used to check those messages.

### The C macros retired

`janet.h` has fifteen `JANET_ATEND_*` macros that form a chain
(`JANET_ATEND_PUT` expands to `NULL,JANET_ATEND_MARSHAL`, and so on) whose only
purpose is to let a C author fill in the first few fields of a positional
initializer without a missing-field warning, and without breaking when a field
is added. Zig's default field values are that mechanism and so a declaration
need only name the fields it sets.

## 13. Modules: built-in types

Almost every native module will need to interact with some of the built-in data
types in Janet. A type crosses to a module author as a view or as a capability.
Section 12 makes the abstract type the native-module interface, and five of its
fifteen slots need something to cross: `tostring` needs a way to append to the
render buffer, `marshal` and `unmarshal` need a stream to write and read,
`bytes` needs to return a view, and `gcmark` needs a `mark` to call.

One rule determines what may cross:

> A type crosses to an author only if it is a read-only view consumed
> without a further crossing, or a capability the runtime passes in and the
> author can only pass back. Anything an author can obtain from a `Value` or
> turn into a `Value` is addressed by that `Value` and never as a pointer. A
> capability is never convertible to or from a `Value` on the author's side.

An indexed abstract's elements are the one read that takes a further crossing.
Its `abi.Indexed` has no storage to point at, so `Indexed` reads each run
through `indexed_chunk`, which takes the abstract as a `Value` and returns a
`Chunk`. The abstract is still addressed by its `Value`, and each `Chunk` is
consumed as it arrives.

`examples/url` is the worked example of this section, as `examples/numarray` is
of section 12.

### The sixteen tags and how each crosses

The table below lists all sixteen tags in six rows, with what each tag crosses
as and which layout in `abi.zig` carries it.

| tags                            | crosses as                        | layout in `abi.zig`            |
| ------------------------------- | --------------------------------- | ------------------------------ |
| nil, boolean, number, pointer   | the `Value`, its payload included | none                           |
| string, symbol, keyword, buffer | the bytes, as `[]const u8`        | `ByteView`                     |
| tuple, array                    | the elements, through `Indexed`   | `Indexed`, `Chunk`             |
| struct, table                   | the pairs, read through `Pairs`   | `DictView` + `KV`              |
| abstract                        | `*T`, the author's own payload    | `AbstractType`, `AbstractHead` |
| function, cfunction, fiber      | the `Value`, its payload opaque   | never                          |

The internal implementation (e.g. the `Array` struct) is not exposed to the
module author.

The table has a row for each of Janet's sixteen tags, so the layouts that carry
a Janet type to an author are a closed set: `ByteView`, `Indexed` with
`Chunk`, `DictView` with `KV`, `AbstractType` and `AbstractHead`. `Chunk` also
carries an indexed abstract's elements to the runtime from its `chunk`
callback. The other layouts in
`abi.zig` carry no Janet type: `Reg` is a registration row, `BuildConfig` is
what the loader checks a module against, `Range` is the pair of indices
`getRange` returns, and `GCObject`, `GCFlags` and `GCData` are parts of
`AbstractHead`.

The closed set is of layouts, not of crossings. A function is not a layout, so
the constructors and the `Value`-form getters (see below) add fields to the
module table without adding to `abi.zig`: the constructors return `Value`s,
and the getters reuse the two views and `Indexed`. An enum is not a layout either.
`Signal` and `FiberStatus` are in `abi.zig` because each is a numbering the
runtime and a module are compiled to agree on, not a type an author is given.

### The four capabilities an author receives

The table below lists four capabilities, each an `opaque {}` in
`src/api/abi.zig`. An author holds a pointer, passes it to a function in
`module.zig` and can neither read a field nor create a capability. (The other
two are used for scheduling and are the subject of section 15.)

| capability  | given to             | runtime type behind it         | operations          |
| ----------- | -------------------- | ------------------------------ | ------------------- |
| `Env`       | a module's `entry`   | `value/tables.zig`'s `Table`   | `cfuns`, `def`      |
| `Render`    | the `tostring` slot  | `value/buffers.zig`'s `Buffer` | `push`, `format`    |
| `Marshal`   | the `marshal` slot   | `marsh.zig`'s `MarshalState`   | `push*`, `isUnsafe` |
| `Unmarshal` | the `unmarshal` slot | `marsh.zig`'s `UnmarshalState` | `pull*`, `isUnsafe` |

The capabilities are named for what they permit rather than for the aggregate
behind.

The two marshal directions are two types. The runtime builds the push side and
the pull side at separate sites, `marshalOneAbstract` and
`unmarshalOneAbstract`, so a `pull*` inside a `marshal` callback has no stream
to read. One bidirectional context made that compile and fail at run time on a
null it had never set; two types make it a compile error at the callback's own
definition.

The capability is the runtime's state struct. `marsh.zig`'s entry points take
`*abi.Marshal` and `*abi.Unmarshal` and each casts back, so the runtime's own
abstract types (`value/ints.zig`, `io.zig`, `peg.zig`, `math.zig`,
`ev/stream.zig` and `ev/channel.zig`) call them as ordinary Zig calls and never
reach the module table at all. The field and the definition of every marshal
crossing therefore spell the same two opaque types, meaning there is nothing to
substitute between them.

Two things beyond the capabilities were needed to make the `unmarshal` slot
reachable at all. A marshalled abstract includes its type's name on the wire
and the unmarshaller resolves that name through the runtime's registry (a type
that never registers fails with `unknown abstract type`).
`module.registerAbstract` is that registration. It can raise since two types
under one name would make a stream ambiguous.

### What an author holds

An author holds no view. A view is the crossing's shape: a pointer and a count.
It is `extern` because a slice cannot cross a `callconv(.c)` signature (see
'Why a slice cannot cross' in section 7). However, it is not a type for an
author to use, and `module.zig` exports neither of the two, nor `abi.Indexed`.
What an author holds is whatever ordinary Zig type is faithful to the storage
behind the view.

As a result:

- Dense storage returns a slice. A string's, a symbol's or a keyword's bytes
  are contiguous, and a byte-like abstract's `bytes` callback returns one view,
  so `getBytes` and `bytesView` return `[]const u8`. A slice rather than an
  iterator, because a slice is what a C library takes.

- Indexed storage returns `module.Indexed`. A tuple's or an array's elements
  are contiguous, but an indexed abstract's are in as many runs as its `chunk`
  callback gives, so there is no one slice to return. `getIndexed` and
  `toIndexed` return an `Indexed`, whose `get` reads by position, `next` in
  order and `nextChunk` a run at a time. A tuple or an array is one run, read
  with no further crossing. An abstract takes one `indexed_chunk` crossing per
  run, and the run read most recently is kept, so a `get` inside it makes no
  crossing. No copy is offered: a module that wants its own block copies the
  runs `nextChunk` returns.

- Sparse storage returns an iterator. A dictionary's storage is a hash array:
  `cap` slots with empties among them, `len` of which are occupied, and that is
  why neither `kvs[0..cap]` nor `kvs[0..len]` is the walk. `getDictionary` and
  `dictionaryView` return `module.Pairs`, whose `next` skips the empty slots
  and returns a `Pair` by value. `Pair` is `abi.KV` under the name `module.zig`
  exports. An author sees no `cap`, no nil key standing for an empty slot, and
  no pointer into the hash array.

How long a getter's result stays valid depends on whether it came from an
immutable type or a mutable one, and every getter's doc comment says which. The
immutable types (string, symbol, keyword, tuple, struct) are stable while the
value is reachable. The mutable types (buffer, array, table) are
`data[0..count]`, and a push or a put may move them. The runtime follows the
same rule internally: finish with what a getter returned inside the call that
obtained it. An `Indexed` over an abstract is valid until the module re-enters
Janet code, and until another run is read from the same abstract, because a
type may return every run from one buffer it reuses. Two `Indexed` over one
abstract are therefore not read in turn.

A `bytes` callback is written over a slice as well. `Spec(T)`'s `bytes` slot is
`fn (*const T, usize) []const u8`, and `define`'s shim builds the `ByteView` the
erased vtable declares. The crossing keeps its layout and no author constructs
one. The runtime reads the view where the callback returns it, so a callback may
return a slice of its own payload.

### Construction as the getters run backwards

A constructor takes exactly what the getter of the same type returns, being
`[]const u8`, so `string(try getBytes(argv, 0))` type-checks. That symmetry is
what the rule implies. The indexed half shares the element type rather than the
container: `tuple` and `array` take `[]const Value`, and `getIndexed` returns
`Indexed`, whose `nextChunk` returns a `[]const Value`. A run is a slice of
the elements, and the value may have more than one. The dictionary half shares
the element type as well: `structOf` and `tableOf` take `[]const Pair`, and `getDictionary`
returns `Pairs`, whose `next` returns a `Pair`. A constructor's argument is
`len` pairs with nothing empty among them, where `Pairs` walks the `cap` slots
of a hash array, so the two are different types. The names end in `Of` because
`struct` is a Zig keyword.

Every built-in type's constructor returns a `Value`, and none returns a
pointer.

### Mutation through the `Value`

Mutation goes through the `Value`, as construction does, and that is why no
`*Table` or `*Array` ever crosses: `get`, `put` and `length` are Janet's own
over any value, and `arrayPush` and `bufferPush` are the two appends they have
no spelling for. The runtime tests the tag on its own side and refuses with its
own message. A generic `get` also does a dictionary lookup without walking
`Pairs`, which is what a keyword-options module needs most of the time.

`get` returns nil for a miss and for a value with no indexed access, which is
Janet's `get` and not a weaker version of it; `put` and `length` refuse what
they cannot use. The asymmetry is Janet's.

### Reading a `Value` outside an argument slot

A getter reads an argument slot, meaning `argv` and an index into it. A value
that came out of a slice or `Pairs`, such as a tuple element from `getIndexed`
or a dictionary value from `getDictionary`, has no slot, so each getter needs a
form that takes the `Value` instead. `toAbstract` is the case that matters
most: section 12 makes the abstract type the native-module interface, and a
module given a tuple of its own abstracts has to read an element.

| reads a slot                              | reads a `Value`                              |
| ----------------------------------------- | -------------------------------------------- |
| `getBytes`, `getDictionary`, `getIndexed` | `bytesView`, `dictionaryView`, `toIndexed`   |
| `getInteger`, `getNumber`                 | `toInteger`, `toNumber`                      |
| `getBoolean`                              | `truthy`                                     |
| `getAbstract`                             | `toAbstract`                                 |
| `getSize`, `getUInteger`                  | none                                         |
| `getRange`                                | n/a; it folds two slots against a length     |

Each `Value` form except `truthy` checks the tag and returns `?T`. A wrong type
is a null rather than undefined behaviour, and the `*View` functions have the
same shape. `toIndexed` returns `Error!?Indexed`, because an abstract's
`length` callback can raise. `truthy` returns `bool`, because every value has a
truthiness.

| function                                     | returns         | null when                                                                     |
| -------------------------------------------- | --------------- | ----------------------------------------------------------------------------- |
| `toNumber(v)`                                | `?f64`          | `v` is not a number                                                           |
| `toInteger(v)`                               | `?i32`          | `v` is not a number an `i32` represents exactly, which is `isInteger`'s test  |
| `toKeyword(v)`, `toString(v)`, `toSymbol(v)` | `?[:0]const u8` | `v` does not have that tag                                                    |
| `toPointer(v)`                               | `??*anyopaque`  | outer null: not a pointer. inner null: the null pointer `pointer(null)` wraps |
| `toAbstract(T, v, at)`                       | `?*T`           | not an abstract, or an abstract of another type                               |
| `toIndexed(v)`                               | `Error!?Indexed` | not an array, a tuple or an abstract with a `chunk` callback                 |

The result is optional rather than raising because a value with no slot gives
the runtime nothing to name in a refusal, and the author can write a better
message: `examples/url`'s 'every query key must be a keyword' says more than
'expected keyword, got string' would. A caller writes
`orelse return panic("...")` where a wrong type is a refusal, and
`if (toNumber(v)) |x|` where it is a branch. The `is*` predicates are for
deciding without unwrapping: `examples/numarray` branches on `isKeyword` to send
a method lookup one way and an index the other, and the lookup takes the
`Value`.

`toKeyword`, `toString` and `toSymbol` return `[:0]const u8` because each of
those types has a real NUL: `value/strings.zig`'s `begin` allocates
`length +% 1` bytes and writes `payload[length] = 0`. The sentinel slice names
that terminator, and the slice is checked in a safe build and not in
`ReleaseFast`. A buffer has no terminator and is read with `bytesView`.

There is no `getCString`. A C string is the bytes slice plus a NUL guarantee,
which a string, a symbol and a keyword have and a buffer does not. A
sentinel-typed getter over the same five types as `getBytes` would have to
refuse a buffer or copy it, and a library taking a pointer and a length, which
is most of them, needs the slice as it stands.

`toAbstract` tests type identity, not only the tag. An abstract of another type
unwraps to a valid pointer into that type's payload, and reading it as a `T`
fails silently. The test is the tag check, `unwrap_pointer`, and a comparison of
`abstract_type.ofAbstract` against `at`. `T` remains the author's claim about
`at`, as it is for `getAbstract`.

`getMethod` reads its key through `toKeyword`, so a key that is not a keyword
returns null, the same as a keyword that names no method.

Two readings have no checked `Value` form. `getSize` and `getUInteger` add only
the wording of a refusal over `getInteger`, and out of a slot there is no slot
to name, so a caller uses `toInteger` and `std.math.cast`. A checked
`toBoolean` would return null for a value that is not a boolean, but nothing
needs that, and `truthy` is sufficient for `(if x ...)`.

The tag test makes no crossing. A module compiles `repr.zig`, and the loader
refuses a module whose value representation differs (section 10), so `checkTag`
reads the tag from the bits, and `toNumber` unwraps the number the same way,
as `toAbstract` reads `AbstractHead.type` without a crossing. What crosses is
what needs the runtime: `checkint` for `toInteger`, which applies the integer
range test, `unwrap_pointer` for `toPointer` and `toAbstract`, and `bytes_view`
for the three C-string unwraps, which read the length off the head rather than
walking to the NUL. The runtime's own hot paths reach `value/helpers/wrap.zig`
by import and make no crossing.

### Alternatives ruled out

- The unwrapped layouts (`Table`, `Array`, `Tuple`, etc), ruled out by the
  thread-local `Vm`. A module links against nothing and resolves no runtime
  symbol, so a module that imported the runtime module would compile its own
  copy of the VM variable, and every operation it called would read and
  allocate against a second VM that nobody initialised. Without the operations,
  the layouts alone would be all a module received, and nothing would catch a
  change to a layout: `api/fingerprint.zig` covers the layouts that cross and
  the loader refuses a module whose number differs, but a runtime type such as
  `Table` is not among them.
- A `Value` for the render buffer. Which buffer reaches a `tostring` depends on
  the caller: `%V` and `print` into a buffer give it an ordinary heap buffer,
  while `description` and `toString` render into a stack local that
  `buffers.init` leaves off the collector's heap list. A stored `Value` would
  therefore sometimes outlive what it points at, and nothing at the callback
  says which case it is in.
- `tostring` as `fn (*T) Error![]const u8`, with the runtime copying. The author
  would have to own storage outliving the call, and a `%v` inside a render
  nests.
- `write` and `print` for `Render`. This imports `std.Io.Writer`'s vocabulary
  for no gain. A `std.Io.Writer` may still be built author-side over `push`.
- `marshalFlags` and `unmarshalFlags` returning the raw `c_int` flag word, with
  the flag re-exported as a constant. Unsafe is the only bit an author has a
  reason to ask about, because the rest of the word is the marshaller's own
  bookkeeping, so `isUnsafe` is the one name. The two flag crossings stay, and
  `isUnsafe` is author-side over them.
- Other names for these types and functions: bare nouns for the marshal pair
  (`marshal.size(n)` and `unmarshal.size()`), which need irregular names on the
  pull side whereas `push` and `pull` do not; `Sink` for `Render`; `Archive` as
  one bidirectional marshal type; `Encoder`/`Decoder`; `ByteStream`;
  `RenderBytes`/`MarshalBytes`; and `RenderStream`/`MarshalStream`, where
  `stream` is already a Janet word.

## 14. Modules: functions

Functions cross the module boundary in both directions. A module gives the
runtime cfunctions to install and calls the runtime through the functions
`module.zig` provides. This section covers how a cfunction is registered and how
its pointer survives the crossing, then the conventions the runtime's functions
follow, how a module reaches the runtime at all, and what an author is given
and what was left out. The types those functions take and return are described
in section 13.

### Function registration

Registering a cfunction gives it a name in an environment, together with the
documentation and the source location the runtime keeps for it. `janet.h` has
two structs for this: `JanetReg`, with a name, a cfunction and a docstring, and
`JanetRegExt`, which adds the source file and the source line. This runtime has
one, `Reg`, with all five fields, each with a default value.

`janet.h` also has four macros for writing the extended struct's initializer:

```c
#define JANET_REG_(JNAME, CNAME)   {JNAME, CNAME, NULL, NULL, 0}
#define JANET_REG_S(JNAME, CNAME)  {JNAME, CNAME, NULL, __FILE__, CNAME##_sourceline_}
#define JANET_REG_D(JNAME, CNAME)  {JNAME, CNAME, CNAME##_docstring_, NULL, 0}
#define JANET_REG_SD(JNAME, CNAME) {JNAME, CNAME, CNAME##_docstring_, __FILE__, ...}
```

The four exist because `JANET_NO_DOCSTRINGS` and `JANET_NO_SOURCEMAPS` determine
which fields a build populates, and the preprocessor's only way to express that
choice is a separate initializer per combination. A comptime `if` expresses it
directly, so the variants are unnecessary.

Accordingly, `corefn.zig` declares `Entry` as the extended shape and populates
conditionally:

```zig
.documentation = if (with_docstrings) (usage ++ "\n\n" ++ doc).ptr else null,
.source_file   = if (with_sourcemaps) sourcePath(where).ptr else null,
.source_line   = if (with_sourcemaps) @intCast(where.line) else 0,
```

One struct, one builder, the flags read once at comptime. In the image
generator, `with_docstrings` and `with_sourcemaps` are `config.docstrings` and
`config.sourcemaps`. In the runtime, `with_docstrings` is false and
`with_sourcemaps` is true. As a result,
nothing in this runtime uses the narrow `JanetReg` shape.

`JanetMethod` is untouched by this. It is `{ name, cfun }` and it is a method
table rather than a registration; it takes named fields and defaults like every
other author-written literal, and stays its own type.

The functions that install a registration in an environment collapse in the
same way. `registry.zig`'s `def(env, n, f, doc)` is equivalent to `defSm(env,
n, f, doc, null, 0)`, and so the narrow form is the wide form with the metadata
left out. For a table of rows, `janet.h` has four entry points, narrow and wide
with a prefixing variant of each; this runtime has two, `cfuns` and
`cfunsPrefix`. Both install their rows through `Installer`, which holds the
environment, the prefix and the name buffer for one installation. It is a
struct rather than a function because `capi.zig`'s `janet_cfuns_ext` receives a
table terminated by a null-name row, which cannot be passed as a slice.

A registration table inside the runtime is a comptime array, and
`corefn.install` appends the terminator row itself so a caller does not need to
write one. `ev.zig` and `os.zig` are the two exceptions. Each assembles the
rows its configuration selects into a fixed-size buffer at run time, writes
`corefn.end` after the last row and then calls `corefn.installTerminated`.

### Why the functions take the capability first

The functions provided by `module.zig` take the capability first: `push(r,
bytes)` rather than `r.push(bytes)`. The capabilities are declared in
`abi.zig`, which imports only `repr`. `build.zig` gives that module exactly one
import, and it is what keeps an author's native module from taking the whole
type catalogue. A method must live inside its type's declaration, so a method
on `Render` would have to reach `api/interface.zig` and `raise.fromAbi` from
inside `abi.zig`. Free functions in `module.zig`, in the pattern of
`cfuns(env, ...)` and `def(env, ...)`, avoid this problem.

### Function pointer alignment

A function pointer passed to the runtime by the author reaches the runtime
inside a `Value`. Under 64-bit nanboxing with a nonzero pointer shift, a
wrapped pointer loses its low bits: `repr.wrapPointer` stores the pointer
shifted right and `repr.toPointer` shifts it back. Both types of function
pointer cross that way, a cfunction (which `module.reg` puts in a `Reg` row)
and a posted callback (which `capi.zig`'s `post` passes to the loop thread in
the event message's `argj` slot).

An author does not need to declare an alignment. The guarantee comes from the
target: `build.zig` caps `-Dnanbox-pointer-shift` at the alignment every
function address has (2 on aarch64, where an A64 instruction is four bytes, and
0 everywhere else). The cap constrains only a function address. Two checks
cover a wrap it does not: (1) `registry.checkPointerAlign` is fatal on a
cfunction or an abstract type whose pointer would not survive the wrap, once at
registration and in every build mode, and (2) `nanbox64.fromPointer` asserts the
low bits are clear on every wrap, in Debug and ReleaseSafe.

### `Method` declaration

Types that can be used by both a native module and the runtime have one
declaration, wherever it sits. `Method` is the exception; the reason is that it
does not cross as itself. The table's `getmethod` and `nextmethod` fields take
`method_type.CMethod`, whose `cfun` is `abi.CFunction`: both fields are
`callconv(.c)` crossings, which cannot name a raising `module.CFunction`. The
runtime casts a `[*]const Method` to a `[*]const CMethod` at those two entry
points. Both types are `extern`, so the cast is sound by declaration, and a
comptime block in `method_type.zig` fails the build if their layouts stop
matching. What crosses is the layout the two share, not the type.

### How a module reaches the runtime

A module reaches the runtime through a table rather than by symbol. The loader
gives `_wattle_init` one `extern struct` of `callconv(.c)` function pointers, and
a module calls through its fields rather than resolving a `janet_*` name.

There is only one copy of the shapes. `api/interface.zig` declares `Runtime`
and both the compiled module and the compiled runtime import it. `capi.zig`
fills a `pub const table: Runtime` from its own definitions. The compiler
type-checks that initializer, so a definition that changes shape fails to
compile against the field it fills. There is no declaration file on the
author's side, because there is only one description of a crossing to keep in
step.

The runtime exports no symbols, and a module exports only `_wattle_init` and
`_wattle_mod_config` (section 10). A module cannot bind to the wrong copy of the
runtime, and a second copy cannot capture the first's crossings.

The interface fingerprint decides whether a module and the runtime agree on the
table. `api/fingerprint.zig` hashes `Runtime`, together with the other
declarations the two compilations share, into one number. The module reports
its number through `_wattle_mod_config`, and the loader compares it with its own
before calling into the module (section 10). The comparison is an exact match,
so the table can change in any way: a field with no caller is removed, and a
module built against a shorter table does not load on a longer one.
Append-only compatibility is not a goal.

A field is named after the `capi.zig` definition that fills it, without a
`janet_` or `zig_` prefix. This approach is not needed in Zig since `rt.`
already qualifies every field. The `new_` and `_value` marks remain: each
records that a crossing does not have the shape of its namesake in `janet.h`,
`new_` where it constructs and `_value` where it mutates.

A call from a module costs one indirect load that a direct call to an exported
symbol would not. The runtime's own code does not pay it: inside `root` those
definitions are reached by import, and only a module's compilation reads `rt`.

### The author surface

An author does not call `rt` directly. `module.zig` puts a function over the
table's fields, and many of those functions wrap one field and add nothing but
the name. This subsection covers the rest: the ways the author surface differs
from the table under it, and why each difference exists.

- **Wrappers, not aliases.** No name in `module.zig` is a `pub const` alias of
  a field. A field of `rt` is read at run time from a pointer the loader
  supplies, so there is nothing to alias until a module is loaded. `nil`,
  `number`, `boolean`, `truthy` and `toNumber` wrap no field: each reads or
  writes the bits `repr.zig` lays out (section 13).

- **Types the table does not have.** `alloc` and `free` take and return typed
  memory. The field underneath, `rt.calloc`, returns `?*anyopaque` for a count
  and an element size. Re-exported untyped, it would put `@sizeOf`, `@ptrCast`
  and `@alignCast` at every allocating call in every module. The `@alignCast`
  is the dangerous one: `malloc` promises no more than `max_align_t`, so at an
  author's call site the cast is an unchecked assumption, and an over-aligned
  payload is undefined behaviour with no diagnostic. `alloc` makes that case a
  `@compileError` naming the type and its alignment. `free` takes the slice or
  pointer `alloc` returned, so the `gc` callback that frees an abstract's
  memory contains no `@ptrCast`.

- **Behaviour the runtime's own functions do not have.** `alloc` returns null
  on failure. The runtime's `gcallocBytes`, which `new` reaches, returns a
  non-optional pointer and calls `fatal` when an allocation fails, so an
  abstract allocation aborts rather than reporting. A cfunction can raise
  instead, so a caller of `alloc` writes `orelse return panic("...")`.
  `examples/numarray` is the worked instance, including the ordering this
  requires. `pcall` always makes a fresh fiber. The runtime's own `pcall` can
  recycle a fiber, and that is an ownership contract no other crossing at this
  boundary has.

- **Two names for one operation.** `cstring` is sugar over `string`. `string`
  takes the length from the slice, which for a sentinel slice equals the length
  the runtime's walk to the NUL would find, so the two return the same string
  for every input either accepts. `module.cstring` does not call the table's
  `cstring` field; `raise.zig` does, to build a panic message inside a module's
  own compilation. `getUInteger` and `getSize` both narrow an argument to an
  unsigned count, and both exist because the refusal a user reads differs: '32
  bit unsigned integer' against 'size'. `getUInteger` is for a width a C
  library takes as `unsigned`.

There are **functions the surface leaves out**:

- `getKeyword`. A keyword argument is read with `getBytes` like any other byte
  sequence, and a keyword in a slice or `Pairs` is unwrapped with `toKeyword`,
  which returns null for anything else.
- `isAbstract` and `isFiber`. `toAbstract` returns `?*T`, which is null unless
  a value is one of the module's own abstracts. An author needs to know that,
  not whether a value is an abstract at all. `isFiber` has no caller:
  `fiberStatus` raises on a non-fiber, which is where a fiber is tested.
- `gclock` and `gcunlock`. They are the lock an author reaches for without
  knowing which value to protect, and `gc.zig` implements them as a nesting
  depth rather than paired tokens: `gcunlock` restores the depth its handle
  names, so a stale handle unwinds every lock taken since it was issued, and a
  missing unlock leaves a runtime that silently never collects again. The
  precise pair, `gcroot` and `gcunroot`, crosses instead: a missed `gcunroot`
  leaks one value.

## 15. Modules: re-entry and scheduling

A module makes runtime code run in two ways. `call`, `mcall` and `pcall`
re-enter the interpreter while the cfunction waits, and the event loop runs a
posted callback later, on the loop thread. The `gcroot` rule below applies
across both.

### What a module roots

Janet's garbage collector runs at two points: between instructions in the
interpreter (after the bytes allocated since the last collection pass a limit)
and inside the `gccollect` builtin. Allocating never collects; it adds to a
running count that the interpreter checks at its next instruction. The
collector keeps a list of every object it has allocated. A collection marks
everything reachable from its roots (i.e. the fibers' stacks, the event loop's
pending state and every value passed to `gcroot`) and frees every object on the
list that it did not mark. A native module's stack is not among the roots, so a
reference held only in a Zig local does not keep its object alive.

This matters to a cfunction because most cfunctions allocate. `string`, `array`
and `tableOf` each create an object on the collector's heap and return a `Value`
pointing at it and, until the cfunction returns that `Value` to the interpreter,
a Zig local may be the only reference to the object. A collection at that
moment would not reach the object from any root and would free it, and the
cfunction would go on to read or return freed memory.

In the ordinary case no collection can run at that moment. While a cfunction
runs, the interpreter is suspended in the call and reaches no instruction
boundary, and no Janet code is running to call `gccollect`. Then, once the
cfunction returns, its result is on the fiber's stack and reachable. The
exception is a cfunction that runs Janet code before it returns, because that
code does reach instruction boundaries and can collect. Four functions on the
surface do that: `call`, `mcall` and `pcall`, which exist to do it, and `length`
on an abstract type with no `length` slot, which falls through to a Janet-level
`:length` method.

`gcroot` is what protects a value across a re-entry, and it is a pair per value.
The root set is a multiset, so a root and its unroot are matched one for one and
the module is what matches them; `gcunroot` reports whether it found a rooting
to drop, so an unbalanced pair is visible during development. The arguments to
`call` and `mcall` need none of this, because they are copied onto the fiber's
stack before the loop runs, which is the region `gc/mark.zig`'s `markFiber`
traces, and neither does the result, which comes back the same way and is safe
until the next re-entry. What needs a root is a `Value` the module built and
keeps across the call, which is reachable from nothing the collector scans.

### Calling back into Janet

The runtime provides three ways to call back into Janet. `call` runs a function
or a cfunction on the current fiber and raises on anything but a return. `mcall`
does the same for a method, looked up by name in its first argument. `pcall`
runs a function on a fresh fiber and reports the signal, the value and the
fiber. `call` and `mcall` are the ones most authors will want; `pcall` is for an
author who has to look at a yield or an error rather than propagate it. `pcall`
is also the only function in `module.zig` that creates a fiber.

A raise from `call` or `mcall` whose callee is a Janet function passes through
four steps: (1) Janet code raises, (2) `vm/entry.zig`'s `call` turns that into
`raise.Error`, (3) the crossing flattens it to a signal return because a
`callconv(.c)` return cannot return an error union, and (4) `module.zig`
rebuilds it with `raise.fromAbi`. A cfunction callee, and `mcall`'s own
refusals, already produce a `raise.Error` and join at step (3). The signal
and its payload stay in `Vm`'s state throughout, as `raise.zig`'s protocol
already guarantees for every other raising crossing; the mechanism is the
existing one at a new depth rather than a new mechanism. `call` and `mcall` turn
a yield or a debug signal into an error with the message `<value> coerced from
<signal> to error`; `pcall` returns them as results instead.

`call` accepts a function or a cfunction and raises `expected function or
cfunction, got <value>` for anything else. Janet code can call more than that:
in `(f ...)`, an abstract value whose type has a `call` slot is called, a data
structure indexes its one argument, and a keyword is looked up as a method on
the first argument and the method is called. `call` is narrowed to the two
function types because a direct dispatch over the rest diverges from
`(f ...)`: `vm.zig`'s `methodInvoke` treats a keyword callee as an index into
its argument, while the interpreter's call opcode resolves it as a method
first. The method call is `mcall` instead, where `(:name ;args)` is
`mcall("name", args)`. `mcall` passes the method it finds to `vm/entry.zig`'s
`callValue`, which accepts every callee `methodInvoke` does, because a method
stored in a table may be any callable value. `pcall` is narrower than `call`: a
fiber runs a function and nothing else, which is also why `(fiber/new print)`
raises.

`isFunction` is the predicate for `pcall`'s rule, and `isFunction` or
`isCFunction` is the test for `call`'s. Both functions refuse a callee only at
the time of the call and with no slot number: `capi.zig`'s `janet_pcall_value`
reports a non-function as `.error`, and `janet_call_value` raises. The case that
matters is a cfunction that takes a callback, stores it, and runs it from a
posted callback later: by then the caller who passed the bad value is gone, so
the cfunction that received it is the only place a refusal can name it.

`FiberStatus` is the type `fiberStatus` returns, for the fiber in `pcall`'s
result. It is declared in `abi.zig` beside `Signal` and aliased by
`value/fibers.zig`, as `KV` is declared in `abi.zig` and aliased by
`value/tables.zig`. It is an enum and not a layout, so the invariant in section
13 does not cover it.

`Called`, what `pcall` returns, does not cross: a `callconv(.c)` return cannot
pass back a struct with a `Value` and an enum without an `extern` layout, so the
crossing returns the signal and writes the two values through out-parameters,
and `module.zig` assembles the struct.

### Scheduling work through the event loop

The event loop's operation can be summarised in one sentence:

> When something happens, resume a fiber with a value.

The runtime's own sources of 'something happens' (its thread pool, its timers,
its file-descriptor backend and its channels) are each built on three internal
operations. Those three operations are all a module needs. A module uses them to
resume a fiber when something happens outside the runtime: in a C library with
its own event loop, or on threads or sockets the module owns.

| operation               | what it does                                                  | callable from                               |
| ----------------------- | ------------------------------------------------------------- | ------------------------------------------- |
| `await()`               | suspends the fiber this cfunction is running on               | a cfunction                                 |
| `post(loop, cb, ctx)`   | asks the loop thread to run `cb(wake, ctx)` at its next turn  | any thread, including a thread with no `Vm` |
| `wake(w, fiber, value)` | puts a fiber back on the run queue, reporting whether it took | a posted callback                           |

The operations need two values, and a cfunction reads both before it suspends:
`loop()` returns the `Loop` that `post` takes, and `rootFiber()` returns the
fiber that `wake` resumes. `examples/digest`'s `sha256` shows the whole
sequence. It reads both values, roots the fiber, starts a thread that holds
both, and returns `await()`. The thread hashes and calls `post`. The posted
callback calls `wake` with the fiber and the digest, then unroots the fiber.

`await` has no field in the module table. It is `raise.signal(.event, nil())`, a
raise with the event signal, which crosses through the table's existing
`signal_record` field.

### `Loop` and `Wake`

`Loop` and `Wake` enforce which thread may do what. Both are `opaque {}` in
`abi.zig`, like the four capabilities in section 13, and both point to the same
runtime struct, `Vm`. They are two types, not one, so that a `Loop` cannot be
passed to `wake` and a `Wake` cannot be passed to `post`; each carries its own
rule about thread and lifetime.

| capability | obtained from                                       | valid                        | usable from     | accepted by |
| ---------- | --------------------------------------------------- | ---------------------------- | --------------- | ----------- |
| `Loop`     | `loop()`, called on the loop thread                 | until the runtime shuts down | any thread      | `post`      |
| `Wake`     | the runtime, as a posted callback's first parameter | for that callback            | the loop thread | `wake`      |

A worker thread is given a `Loop` and can do exactly one thing with it. The
posted callback receives a `Wake` and is the only place a fiber can be resumed.
Nothing else on the surface accepts either, and every other function finds `Vm`
through a thread-local a worker thread does not have, so a module resuming a
fiber from its own thread is unspellable rather than undocumented.

`Loop` is the first capability an author asks for rather than receives, and the
first kept across a thread boundary. Because a `Loop` is invalid once the
runtime shuts down, a module that gives one to its own thread must stop that
thread first. The thread is not told about the shutdown, so the module stops it
from a finalizer instead: an abstract value owns the thread, and its type's `gc`
callback joins it. Teardown runs every finalizer before it releases the loop, so
the join finishes while the `Loop` is still valid.

Other names are not reopened. The four capabilities in section 13 are named
with a noun (`Env`) or a verb (`Render`, `Marshal`, `Unmarshal`), and
`Scheduler` for `Loop` would add an agent noun as a third style. `Resume` for
`Wake` would collide with the synchronous `resume` described under 'What the
loop does not offer', and `Schedule` reads as a timetable.

### Posting and waking

`post` writes an event to a pipe that the loop thread reads, and the loop runs
each event's callback as it reads the event. (On Windows the completion port
takes the event instead of a pipe.) An author can rely on four things:

- Any number of modules and threads may hold a `Loop` and post at once. The
  runtime's own thread pool already writes to the same pipe from several
  threads, and one event is smaller than the size up to which a pipe write is
  atomic, so events written at the same time never interleave.
- Callbacks run one at a time on the loop thread, in the order their events
  arrive. Posts from different threads arrive in whatever order their writes
  complete, so a module cannot rely on its callbacks running before or after
  another module's.
- A post is never dropped. The pipe's write end blocks, so a thread posting
  faster than the loop reads waits in the write.
- A post made while the loop is not running stays in the pipe, and its callback
  runs at the loop's next turn.

Arranging a wake before suspending is not a race either. The loop is
single-threaded, so an event posted before the cfunction returns is not read
until the fiber has suspended.

The fiber a module keeps across the wait is a `Value` under the `gcroot` rule
in 'What a module roots': `gcroot` before `await`, `gcunroot` in the callback
after `wake`. From the wake onward `ev.scheduleGeneral` keeps it in
`active_tasks` as well; before the wake only the root does. A `false` from
`wake` is a state to clean up after rather than a failure to report, because
`ev/cancel` may have moved the fiber on, or it may have finished, and the
context is the module's to free in the callback either way. The callback cannot
raise, which is the contract the six non-raising abstract-type slots already
have; building a `Value` inside one is still allowed, because the collector's
allocation is fatal on failure rather than a raise and no safe point runs
between fibers on the loop thread.

`GenericMessage`, the runtime's event message, is not part of the module
surface. `capi.zig`'s shim stores the author's context in the message's `argp`
field and the callback, as a pointer-tagged `Value`, in its `argj` field; the
trampoline unpacks both on the loop thread.

### Checking the thread

A crossing checks that its thread is running Janet, with the exceptions below.
The probe is the one `gc.gcallocBytes` has always used, `vm/state.zig`'s
`isInitialised`, over the thread-local symbol cache, with a message naming the
thread rather than the embedder. It lives in the boundary shims only:
`capi.zig`'s entry points and `args.zig`'s generated `*Abi` shims.

A thread that is not running Janet has no runtime state; the thread-local that
holds it is all zero. The check stops such a thread at its first crossing,
before anything reads that state. Two kinds of crossing therefore skip it: one
that reads no runtime state has nothing to protect, and one that can run only
after another checked crossing on the same thread would never see a bad thread,
because the earlier check has already aborted.

The seven crossings are:

- The three wraps (`wrap_string`, `wrap_abstract` and `wrap_pointer`), which
  build a `Value` from their argument and read nothing else.
- `post`. A module's own thread is meant to call it, and that thread has no
  runtime state. `post` needs none: the `Loop` it is given points to the
  runtime that receives the event, and `ev.evPostEvent` takes that target
  explicitly.
- `c_raise_record` and `c_raise_take`, which `raise.zig` uses to carry a raise
  across the boundary as a flag. An author cannot call either, because
  `module.zig` does not re-export `raise`, and `raise.fromAbi` reads the flag
  only immediately after another crossing, which has already checked.
- `fatal`, the abort behind `raise.total`. It runs only after a raise, and it
  reads no runtime state.

`signal_record` (which records a raise's signal and payload) is part of the same
raise machinery as the flag pair, but it keeps the check. `await` is
`raise.signal(.event, nil())`, and `nil()` makes no crossing, so on a module's
own thread `signal_record` could be the first crossing that reads runtime
state.

The check costs one thread-local read per crossing. On some targets that read
is a function call; on others it is a single memory load. The interpreter makes
no crossings and does not pay it.

### Builds without the event loop

In a build without the event loop (`config.ev` off), `loop`, `post`, `wake` and
`await` still exist, so a module that uses them compiles and loads. Calling
`loop()` raises `event loop not enabled`, and `post` and `wake` cannot be called
without the `Loop` and `Wake` that only a running loop provides. The error comes
at the first call rather than when the module loads, because the configuration
bits the loader compares do not record whether a build has the event loop.

### What the loop does not offer

The module surface exposes none of the runtime's own sources of events. A
module builds what it needs from the three operations, and any of these can be
added if a module needs it:

- The thread pool (`threadedCall`). A module starts its own `std.Thread` and
  posts from it.
- Timers. `sleep(seconds)` over `ev.sleepAwait` would be one crossing.
- Streams and async listeners. `makeStream` and `asyncStart` would give an
  author the runtime's own abstract type and a `*Fiber`, and a listener runs
  with no scope above it. A module with sockets polls them on its own thread
  instead. A constructor that wraps a descriptor as a `core/stream` is the
  likelier addition.
- Channels. A module can produce values in the background with `post`.

There is also no synchronous `resume(fiber, value)` for driving a Janet
generator past its first yield. `wake` only queues a fiber; `resume` would run
it inside the calling cfunction.

## 16. The indexed protocol

A _protocol_ is a set of callbacks through which the runtime reads an abstract
type as it reads a built-in type. It is called a protocol rather than an
interface because "interface" already names the native module interface
(`api/interface.zig`). The indexed protocol is the one this runtime has: an
abstract type that implements it is read wherever an array or a tuple is read.

Reading an indexed value used to mean taking a pointer to its elements and a
count. A collection that does not keep its elements in one block has neither.
A persistent vector is a tree of small blocks, so splice, `apply`, the slices
and the `take` and `drop` family could only refuse one, and Janet code could
not pass one to a library that expected an array or a tuple.

### What a type provides

A type implements the protocol with the `chunk` callback, the fifteenth slot
of `AbstractType` (section 12). `chunk(p, index)` returns a `Chunk`: the run of
elements that holds `index`, and the index of the run's first element. A
vector's leaves are already such runs, so it answers without copying.

- A type with `chunk` also has `length`, which bounds the index. `define`
  refuses a `chunk` without a `length` at compile time.
- The slot's presence is the declaration. A separate flag would cost the same
  two reads, the abstract's type pointer and a field of the type, and would let
  a type claim to be indexed without being readable as one.
- `chunk` cannot raise, allocate or run Janet code (section 12), so a run
  cannot change while a reader holds it.
- The name is for what the callback returns. `indexed`, by analogy with
  `bytes`, was rejected: `bytes` returns the whole value in one view, and a
  name for what the type is read as would suggest that shape.

A type need not store `Value`s. A run is a `[]const Value`, and a type that
stores something else, such as `examples/numarray`'s `f64`s, converts its
elements into a buffer in its payload and returns that. It converts rather
than reinterprets, because an `f64` has a `Value`'s bits only under NaN
boxing, and even there a NaN element would read as a pointer. The buffer
exists before the call, because the callback cannot allocate, and the type's
`gcmark` marks any `Value` that only the buffer refers to.

The protocol is opt-in, and no value that exists without it changes. No byte
type implements it, so `indexed?` and `bytes?` stay disjoint. Janet's core
relies on that: `take` and `partition` test `indexed?` before `bytes?`, so a
string that answered `indexed?` would come back from `(take 2 "abc")` as
`(97 98)`.

### How long a run is valid

A run is valid until the next call that can allocate or run Janet code, or
until the next `chunk` call on the same value.

The first two clauses are the rule an array's own elements already have, and
the collector does not move objects, so a reader learns nothing new. The third
exists for a type that converts into one reused buffer, which cannot hand out
two runs at once. Keeping a buffer for every live run would cost exactly the
types the protocol means to admit. So a reader holds one run of a value at a
time, and a site given the same value twice, as `(array/concat @[] v v)` is,
finishes with one run before taking the next.

A module reads through `wattle.Indexed`, whose rule is looser about
allocation (section 13).

### Where a value is read

Every site that reads a Janet program's value as indexed reads it through
`args.chunks`. It gives an array or a tuple as one run and an abstract as the
runs its callback returns, and `Chunks.window` narrows the read to a range, so
a slice of a vector does not walk from zero to reach its start. A run that
does not hold the index asked for, or that reaches past the length, is
refused.

A site that needs every element in one block uses `args.gather`, which borrows
an array's or a tuple's block and copies an abstract's runs into one on the
scratch heap. `os/execute` hands its arguments over as one array of C strings,
the FFI passes elements on as an argument list, and a PEG's `cms` pushes each
element through a call that allocates.

The runtime's own reads of tuples and arrays it built use `args.items`, which
answers for those two types only.

Four rules hold at a site:

- Room for every element is reserved, from `Chunks.len`, before the first run
  is taken, because a run does not survive an allocation.
- An opcode commits its program counter before it reads, as `.length` does,
  because an abstract's `length` callback can raise and run code.
- A guard that exists only because a callback runs code, such as bounding a
  copy against a count that changed or filling a fresh tuple with nil, sits on
  the abstract arm. Nothing between two passes over an array or a tuple runs
  code. On every path, those guards cost 13% on a `tuple/join` of two
  three-element tuples and 10 to 14% on a `string/join` of six short parts.
- `Chunks.next` is `inline`. Without it, appending a few elements to an array
  with room cost 13% more than the loop it replaced, the call being most of
  the operation at that size.

### What Janet code sees

`indexed?` answers true for an abstract whose type has `chunk`. Were it to
answer false, code that checks a value before acting on it would fail where
code that acts directly succeeds, and `match` would never match a vector. With
it true, `take`, `drop`, `match` and `flatten` read a vector a Janet library is
given. The predicate answers true only once every site reads through the
protocol, because it promises that the value is read wherever an array or a
tuple is.

A site that reads an indexed value names the protocol when it refuses:
'expected indexed value, got 5' where the C implementation says 'expected
array or tuple, got 5', and `slice`'s 'expected string, symbol, keyword,
buffer or indexed value, got 5' where it says 'expected string, symbol,
keyword, array, tuple or buffer, got 5'. `indexed?`'s docstring says the same. The old text
would be narrower than what the site accepts. This is the fourth difference
the Introduction allows. A refusal is rendered from a tag set, which cannot
name a protocol, so these refusals have their own spelling.

The `tchck` opcode passes an indexed abstract where its tag set includes both
array and tuple, as `(tchck 0 :indexed)`'s does.

No callback builds a result. What `take` returns is the environment's to
decide: Janet's `take` calls `tuple/slice`, which returns a tuple whatever it
reads. The shared runtime only reads.

### How a site is tested

A probe type in each contract that covers a site returns every run from one
buffer, overwritten on each call, and the site is given the same value twice.
A site that holds two runs of one value then fails, where a vector, which hands
out its own leaves, would let it pass. The probe is declared per contract
because contracts share no declarations.

A site's expected result is written out when `boot.janet` does not use the
site. A tuple holding the same elements goes through the same `args.chunks`
code, so an oracle built from one moves whenever the subject does.

### What the protocol leaves out

- Writes. `sort` needs to set an element, and a mutable protocol is a separate
  decision from a readable one.
- Dictionaries. A persistent map has the problem a vector had, with structs
  and tables, and its protocol is to be designed after this one has been used.
- Sequences. A string's elements are bytes, with no `Value`s for a run to hold,
  so a protocol for going through elements in order, without random access or
  `Value` storage, is where strings belong.
