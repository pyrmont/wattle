# Style guide

How the source under `src/` is documented. `AGENTS.md` says how a pass over a
file is verified; this file says what the result looks like.

The sentence rules, and the rule that a block is dry, also govern the
READMEs under `src/`, `test/`, `res/` and `examples/`, and the example
sources. The header and layout rules are for Zig source. A pass over
a document changes its shape and not its facts: every count, measurement,
citation and decision stays, and a reason for a decision is a fact. What a
pass deletes is a sentence that only appraises.

A document states each decision and its reasons as they stand. When a
decision was taken, which increment applied it, and what a section used to say
are the working record's, and belong in `notes/`, which is not tracked. A date
appears in a tracked document only inside a fact that needs it, such as an
upstream commit's title.

## Where explanation goes

`src/module.zig` is the reference. Every other file under `src/` is to be
brought to its shape. The rules below are read off it.

**A doc comment says how to call the declaration.** Why the declaration is
shaped as it is goes in the file's own header or in `src/README.md`, and how
it came to be goes in `notes/`. A doc comment cites no increment, phase, date
or measurement, and no untracked document. An
invariant the file maintains is a rule in the file header, not a story told
on the function that happens to depend on it.

## The `///` block

**A `///` block has a fixed order.**

1. One sentence, present tense, verb first: "Wraps ...", "Returns ...",
   "Checks that ...", "Gets and unwraps ...". A type gets a noun phrase:
   "The return type of `pcall`."
2. What the parameters mean, by name in backticks, in prose. No parameter
   list.
3. Failure, in a fixed sentence: "This function raises if ...", "This
   function returns null if ...", or "This function cannot raise." For an
   unchecked function: what is not checked, what happens when it is violated,
   and what to call first.
4. Facts that change how it is called: lifetime and stability of a result,
   which thread may call it, re-entry, defaults.
5. A reason only where it changes the call, in one sentence: "The result is
   `[:0]` because a keyword is interned with a terminator."
6. A ```zig block when the calling shape is not obvious from the signature.
7. Cross-references last: "See `push`, which this is a convenience over.",
   "See also `pcall`."

Not every block has every part. A one-line block ("Wraps `true` or `false`.")
is complete when the signature says the rest.

**Sentences are short and plain.** One idea each, about fifteen words. No
bold. No `--` dashes; end the sentence instead. No "which is why", "and that
is a contract", "not X but Y", "the whole point": state the fact and stop.
No history, no measurements, no dates.

**A block is dry.** It states a fact or a mechanism in plain words and
evaluates nothing. No idiom ("is a miss", "the obvious move", "is sugar
over"), no adverb of manner where the fact is already stated ("quietly",
"silently"), no aphorism ("refusing says what happened"), no appraisal ("a
real outcome", "worth copying", "the obvious Zig transliteration"). Brevity,
clarity and accuracy are the goals, and a sentence that serves none of the
three is deleted rather than reworded. A comparison with an original states
what the original did and what this code does, and stops. It names the
original's behaviour and not its author's intent ("the C original's
behaviour", never "the C original's choice"), and it does not say that the
behaviour "is kept": the code beneath is the record of that.
`examples/numarray/numarray.zig` `inRange` and `numArrayPut`.

**Siblings repeat rather than cross-reference.** Every `get*` repeats the
same `argv` sentence verbatim. A reader lands on one declaration and reads
only its block, so each block stands alone.

**One vocabulary.** "the runtime", "a module", "the caller", "an author";
"wrapped" and "unwrapped"; "raises". A term of art is defined in italics on
first use in the file header (_crossing_, _view_, _capability_) and then
used unchanged.

**No metaphor.** A doc comment is technical writing, and its goals are
brevity, clarity and accuracy, so a word means what it means in Zig or in the
runtime. Personification is the metaphor to watch for. A type, a value or the
runtime is not an actor: a struct does not "carry", "hold" or "know" a field,
a value does not "carry" a tag, and nothing "wants" or "answers"; "agree" is
written only for two things being equal, never for consent.
"Carry" is not a term of art and is not used at all. Write "include", "have"
or the plain relation: "The `data` field of `GCObject` is this type", never
"`GCObject` carries one as its `data` field"; "a marshalled abstract includes
its type's name"; "a value with this tag"; "the pointer type has alignment
`fn_align`".

**Nothing stands in for the subject.** A block names the type it documents,
or writes "this type", and never writes "one" for it. Write "`loop` returns
a `*Loop` and `post` takes a `*Loop`", never "`loop` returns one and `post`
takes one": a reader should not have to recover what "one" refers to. The
same holds for any noun: "the later entry runs", never "the later one runs".

## Wattle docstrings

**A Wattle docstring is in the indicative mood.** It applies to the docstrings
in `src/boot/boot.wattle` and to the docstring argument of `corefn.reg`,
`module.reg` and the other registration helpers. The first sentence is present
tense, third person, verb first: "Defines a function.", "Checks whether `x` is
empty.", "Returns the current fiber." A sentence that describes behaviour is
indicative throughout: "Returns nil if `key` is absent", never "Return nil if
`key` is absent". A binding that is a value rather than a function gets a noun
phrase: "Bound to an array of lint messages."

The rest of the `///` rules apply to a docstring unchanged, including the ban
on personification and the plain vocabulary. Signatures are not part of the
docstring; they are stored under `:sigs`.

**A docstring marks a name with a sigil, not with backticks.** Three kinds of
word appear in a docstring, and each is written one way:

- An argument of the binding is written bare: "Checks whether xs is in
  ascending order." `doc` underlines every whole word in the prose that is
  an argument named in `:sigs`, so the docstring does not mark it.
- Another binding is written with a leading `^`: "Like ^get, but returns nil
  for a missing key." The name after `^` must be bound in the core
  environment or be a core dynamic binding, which `test/suite-boot.wattle`
  checks. A `^` inside a word, as in `a^b`, is an ordinary character.
- Backticks enclose raw code only: an expression, a keyword, a literal, a
  string of another language. A name is never raw code.

**A signature names each argument by its role.** The same name means the same
thing in every signature, so a docstring reads the same way wherever it
appears:

| name                | role                                                    |
| ------------------- | ------------------------------------------------------- |
| `x`, `xs`           | The value the function reads or transforms.             |
| `val`, `vals`       | A value the function stores, sends, writes or converts. |
| `arr`, `buf`, `tbl` | An array, a buffer or a table the function modifies.    |
| `coll`              | A collection, in a function written in Wattle.          |
| `fmt`               | A format string.                                        |
| `i`                 | An index.                                               |

`x` is the first argument, and `xs` is the rest argument of that role when it
is in first position. `vals` is the rest argument of the `val` role, and also
the rest argument that follows `fmt`. `at` is the position in `array/insert`,
`array/remove` and `buffer/format-at`.

Two rules decide between `x` and `val`. A name is `x` only when the argument is
first, so a value in any later position is `val`. A conversion that writes into
a container, such as `int/to-bytes` and `marshal`, takes `val`, because the
value goes into the container. A conversion that returns a new value, such as
`int/to-number` and `int/s64`, takes `x`.

The exceptions are `math/atan2`, which is `(math/atan2 y x)`, `math/pow`, which
is `(math/pow x exp)`, and `os/clock`, whose `format` is the type of the output
and not a format string. A docstring that names a container writes its type
after the name: "Appends the bytes to buf, a buffer."

## The `//!` header

**The `//!` header** says what the file is in one sentence, how it is
reached, the terms it uses, and the rules that hold in it as a bulleted list
with each rule's reason in the same bullet. The file an author enters by also
says where the worked examples are; a file reached through that one does not
repeat them, and does not repeat anything else that file already says.
`##` headings name a topic of the file ("How a module reaches the runtime"),
never a category from this list ("Terms", "Rules"). A term is defined in
italics in the paragraph where it first matters, and a rule sits under the
heading of the topic it belongs to.

## Comments inside a body

**No comment block sits between declarations.** Explanation goes in the
header or in the `///` block of the declaration it is about. A `//` comment
inside a body sits directly above the lines it is about and says what they
do, or why they are where they are, in one or two sentences. A reason that
is about one call goes there rather than in the `///` block, so the call and
its reason are read together; the `///` block keeps the summary, the
parameters, the failure sentence and the calling facts. A `//` line never
points at the header or another block for its content.
`examples/numarray/numarray.zig` `numArrayUnmarshal`: the reason the
elements are allocated before `wattle.pullAbstract` sits above the
allocation.

## File layout

**File layout** is banners in a fixed order: standard library imports,
project imports, compile-time imports, constants, aliased types, types, public
functions, private functions, tests. A file has each banner at most once,
and only the banners it needs. Compile-time imports is one `comptime` block of
`_ = @import(...)` lines, for files analysed for their exports rather than
named by a caller, with the `options` import it reads declared above it;
`src/root.zig` is the file that has one. Tests holds both the file's `comptime`
assertion blocks and its in-file `test` blocks, ordered by the declaration each
one is about; a block that no longer sits beside its subject names it in its
first line. Alphabetical within each banner, except inside that block, which
keeps its own grouping. A run of declarations that share one `///` block also
keeps its own grouping and sits where its first member sorts, so alphabetical
order applies between runs, and within a run unless the run's own order
carries meaning, such as a numbered table or a bit order, in which case the
run keeps that order and its block says so. Under Standard library imports,
`std` comes first and `builtin` second, which is Zig's own convention. Private
functions are documented too, more briefly.

**A contract file** takes two of those banners differently. It is a file under
`test/` whose only public declaration is `run` and whose cases are functions
`run` calls. The five banners that hold what is file-wide apply to it
unchanged and sort the same way: standard library imports, project imports,
constants, aliased types, types. In place of public functions and private
functions it has Cases and then Entry. Cases opens with the helpers more than
one case shares, then holds the case functions in the order they are called,
which is the order the contract runs them in, so it is not sorted; a fixture
one case reads sits immediately above that case rather than under Constants.
Entry holds `run`, and the private `body` above it where the file has one.
There is no Tests banner, because a contract's cases are what a test block
would otherwise hold. A fixture under `test/module-errors/` is a module
written to fail to compile, and it has its header and its imports and no
banners at all.

## Rules read off the two files

The rules above were moved from `AGENTS.md`. The rules below are
inferred: `src/module.zig` and `src/api/abi.zig` (its header through
`FiberStatus`) both follow them, and the moved text does not state them.
Each cites one declaration in each file that exhibits it.

**The header opens untitled.** A noun-phrase sentence naming the file opens
the header, as a paragraph of its own. One or more untitled paragraphs
follow, saying what the file is and how it is reached, before the first `##`
heading. `module.zig` lines 1 to 13; `abi.zig` lines 1 to 11.

**A `##` heading is sentence case and names a topic.** It is a noun phrase
("Values across a re-entry into Janet code") or a question-word phrase ("How
a module reaches the runtime"). `module.zig`: "Declaring an abstract type".
`abi.zig`: "What belongs in this file".

**A header's bulleted list puts a blank `//!` line between bullets** and
continues a bullet with a two-space hanging indent. `module.zig`: the four
re-entry rules. `abi.zig`: the five kinds of declaration.

**A term is defined in a copula sentence** with underscore italics: "A _view_
is ...", "Each field is a _crossing_: ...". Every later use is plain,
lowercase and unitalicised. `module.zig` lines 23 and 28; `abi.zig` lines 6
and 43.

**A type's block names its producers and consumers right after the summary.**
A type has no calling shape of its own, so the second paragraph says which
functions return the type and which take it. `module.zig` `Dictionary`:
"`getDictionary` and `toDictionary` return a `Dictionary`." `abi.zig`
`ByteView`: "`module.getBytes` and `module.bytesView` return a `[]const u8`
built from the `ByteView` the runtime gives them."

**A capability's block opens "The capability to <operation>."** and then
names the function that returns a pointer to it and the functions that take
that pointer. `module.zig` `Loop` names `loop` as the function that returns
and `post` as the function that takes. `abi.zig` `Env`: "This type is an
argument passed to `module.nfuns` and `module.def`".

**A struct's fields are described in the container's block, by name in
backticks, in prose,** the way parameters are. A field that its type already
explains is not named. `module.zig` `Called` names `signal`, `value` and
`fiber`; `Dictionary` names `count` and `len` and leaves `position` and
`rest` to the code. `abi.zig` `Dictionary` names all four; `AbstractHead`
names none.

**A `//` group comment inside a struct is one line: a noun phrase ending in a
full stop, with a blank line before it.** The same group has the same
label in both files: "The collector.", "Access.", "Identity.", "Rendering.",
"Marshalling." `module.zig` `Spec`; `abi.zig` `AbstractType`.

**Paragraphing follows the kind of declaration.** On a type or a function the
summary sentence is a paragraph of its own, and each further part of the
fixed order is its own paragraph, separated by a blank `///` line. On a
constant, an alias or a field the block is one paragraph. `module.zig`
`Called` against the `Loop` alias and `Spec`'s `gc` field; `abi.zig`
`AbstractHead` against `AtomicInt`.

**A constant's block is a noun phrase saying what the number is, not its
value.** `module.zig` `max_table_rows`: "The most rows `nfuns`, `getMethod`
and `nextMethod` accept in one table." `abi.zig` `abstract_payload`: "The
offset to an abstract's payload from the beginning of its allocation."

**An alias's block depends on whether an author writes the shape out.** For
an alias whose shape an author never writes (the six capabilities,
`AbstractType`, `Reg`, `Signal`, `Value`) the block is one paragraph of at
most two sentences: the noun phrase, then which function returns or takes the
type. `module.zig` `Loop`: "The capability to ask the event loop to run a
callback at its next turn. `loop` returns a `*Loop` and `post` takes a
`*Loop`." An alias whose fields, members or signature an author writes by
hand gets the full block, with a ```zig block for the shape.
`module.zig` `Method` shows the row literal an author writes. `abi.zig`
`AtomicInt`: "The width of a refcount."

**A count is a word; a literal is spelled as the code spells it.**
`module.zig` header: "Seven of the fifteen return no error union", "Three
functions callable by a module author may re-enter"; `getRange`: "defaults
to 0", "`-1`". `abi.zig` header: "There are five kinds"; `FiberStatus`: "The
first fourteen values".

**A declaration in the same file is a bare name. A declaration in another
file is qualified by the alias a reader would write.** A file is named by its
path under `src/`, without the `src/` prefix. `module.zig` header:
"`api/interface.zig` declares an `extern struct`", `define`: "`Spec(T)`
describes". `abi.zig` `AbstractType`: "`module.define` returns",
`ByteView`: "`api/abstract_type.zig` checks the author's struct literal".
See the open question on `module.zig`'s own spelling.

**A `///` block may point at a worked example by its path under
`examples/`,** in the cross-reference position. `module.zig` `alloc`: "See
`examples/numarray/numarray.zig` for a worked instance." `abi.zig` `Env`:
"See `examples/numarray/numarray.zig`."

**Spelling is British.** `module.zig` line 71: "marshalling". `abi.zig` line
122: "recognise".

**Comment lines wrap at 80 columns.** No `//!`, `///` or `//` line in either
file is longer, while code lines may be. `zig fmt` does not wrap comments, so
this is by hand.

**The vocabulary also has:** "the loader" (`module.zig` line 4; `abi.zig`
`BuildConfig`), "the collector" (`module.zig` line 118; `abi.zig` group
comment "The collector."), "payload" for the bytes behind an abstract
(`module.zig` `abstract`; `abi.zig` `AbstractHead`), "nfunction" as one
word (`module.zig` `NFunction`; `abi.zig` `NFunction`), "callback" for a
slot of an abstract type (both `AbstractType` blocks), and "Janet" for the
language with "the runtime" for the implementation (`module.zig` `call`:
"Janet code"; `abi.zig` `AbstractType`: "Janet supports user-defined
abstract types"), and "machine word" for the unit a `Value` occupies, never
"word" alone in that sense; "flag word" names the collector header's field
and "a Janet word" a name in the language.

## Rules read off the examples and the documents

The rules below were read off the pass of 2026-09-07 over the example
sources, the READMEs and the since-retired design document, and off the
user's own edit to
`examples/numarray/numarray.zig`. Each cites the site it was read from.

**The header says how the file is reached before its first topic, and does
not argue for it.** The sentence naming what builds, loads and runs the file
follows the opening sentence and precedes the first `##`. It states the
fact; a clause saying why the file deserves to be exercised is not part of
it. `numarray.zig` lines 3 and 4, where "because a sample nothing executes
is a file rather than an example" was removed.

**A `##` heading names a broad topic, its `###` headings name the
instances, and the `##` opens with a paragraph that introduces them.**
`numarray.zig`: "Differences with the C version" opens with the paragraph
naming `numarray.c`, and "Type casting" and "Callback list" sit under it.

**A heading is a short noun phrase.** Two or three words where they name the
topic; a heading is not a description of its section. `numarray.zig`: "Type
casting" replaced "The cast at the head of every callback", and "Callback
list" replaced "The `JANET_ATEND_PUT` chain".

**A function, a test or a check is not an actor either.** The rule against
personification covers every thing in the code. A function does not decide,
a value does not fall out of a test, a branch does not want, and a header
does not answer an include. Write the check: "this function is the one
check for a negative index", "`index >= size` held for it without a separate
check". `numarray.zig` `inRange`, the two sentences the user marked.

**A sentence does not comment on the sentence before it.** A sentence
beginning "That is" or "This is", or a clause beginning ", which is what" or
", which is why", restates or appraises what came before. It is merged into
the sentence before it or deleted. In the retired design document, "That is
what settles it." went, and "That is what `raise.fromAbi` exists for" was
merged into the sentence before it.

**A block does not close by restating its point or narrating the code
beneath it.** `numarray.zig` `inRange`: "So the conversion is written out."
was dropped, because the conversion is the three lines that follow; the
sentence "Clamping gives wrong data where the other two give a refusal" was
dropped, because the two sentences before it had said so.

**In an example, a reason stays where it changes what an author does, and
sits above the call it is about.** A reason that decides an order or a
check is a `//` comment on the line that does it, in one or two sentences,
in the interface's own words: above the allocation, "Allocated before
`wattle.pullAbstract`: from the moment that returns, the block is on the
collector's heap list and `numArrayGc` may run on it." A reason for the
interface's own shape belongs to the interface's own block and is not
restated; a term from the runtime's interior ("the reference
table", "an entry point on the boundary") is replaced by what it means for
the author. `numarray.zig` `numArrayMarshal` and `new`.

**In an example, a reason recorded elsewhere in the tree is cited and not
restated.** The citation names a tracked file a reader can open, and carries
enough of the reason to be worth reading on its own: "This function cannot
raise, as `module.zig`'s `define` records: a finalizer runs inside a
collection, where nothing could act on a report." `numarray.zig`
`numArrayGc`.

**An nfunction's block names its Janet call shape, and a callback's block
names its slot.** After the verb-first sentence: "Implements
`(numarray/scale numarray factor)`." or "Implements the `gc` callback." An
nfunction's parameters are `argv` slots by number ("`argv` slot 0 is the
numarray and slot 1 is the factor"), and its failure sentence lists the
arity and each slot's type. `numarray.zig` `scale`, `numArrayGc`.

**In a file under `examples/`, a name reached through `@import("wattle")` is
written `wattle.name`.** The alias a reader writes is the author's alias. A
declaration in the same file stays bare, and a callback slot named as a
field (`gc`, `put`) stays bare. `numarray.zig` `new`: "`wattle.new` returns
a block"; `defs`: "`wattle.registerAbstract` refuses".

**An example keeps its own banner order.** The callbacks, the nfunctions,
the module: the order a module is read in. The banner form is the
three-line form; the fixed order for `src/` does not apply. `numarray.zig`
lines 53 to 55.

**No second person.** "you" and "your" do not appear. Write "the caller",
"an author" or "the reader". `test/README.md`, "whenever the tree's own
include path changes" for "whenever your own include path changes".

**A `--` inside a command-line flag is a literal.** `--check`, `--fuzz` and
`--atExit` are spelled as the tool spells them; the rule against `--`
dashes is about sentences.

**Quoted text keeps its own shape.** A block quote or an inline quotation
of upstream text, of a retired file or of a superseded paragraph keeps its
bold, its dashes and its spelling, because it is evidence. A block quote
that is the document's own rule follows the rules. In the retired design
document the quoted `janet.h` comment was unchanged, and the crossing rule
lost its bold.

**A claim-shaped heading becomes a topic, and the claim becomes the first
sentence of its section.** A numbered section keeps its number, because a
citation of it names the number and never the title. From the retired design
document: "The tag's type" over "The tag is an `enum` rather than a `u4`."

**In a Markdown document, a bold lead-in becomes a heading where it opens a
topic and a plain sentence where it does not; italics define a term and do
nothing else; a table row is exempt from the 80-column rule and its content
follows every other rule; a fenced block is code and is not touched, except
that a `//` comment inside a Zig fence is prose.** `examples/digest/README.md`
for the headings; `examples/numarray/README.md` for the fence comment.

**The vocabulary rule's list of words that personify also has:** "buy" and
"earn" (write "gain", "secure" or "justify"), "hand back" and "hand over"
(write "return" or "pass"), "answer" (write "return" or "report"), "wear",
"dissolve", "knock", "bite" and "decide" of anything but a person. A
metaphor that is not a personification goes too: "a knot to untie", "the
other side of the same wall", "rotted away". `examples/standalone/build.zig`.

**Only a person decides.** A document or a section "records the decision
that". A configuration, an option, a rule or a constraint "determines",
"selects" or "sets". A function or a mechanism is described by what it does:
it checks, points, resolves at compile time, propagates or flattens. A
passive ("how nullability is decided") may stand where no actor is named,
and "wanted" in a passive becomes "needed" or "required".
`examples/numarray/README.md`: "`config` determines `Value`'s layout".

## Open questions

Where the two files disagree, or where only one of them exhibits a rule,
the rule is not recorded above. Each item says what the pass over the rest
of `abi.zig` did in the meantime.

- **Repetition between headers.** `abi.zig`'s header redefines _crossing_,
  _view_ and _capability_, which `module.zig`'s header defines. The header
  rule says a file reached through `module.zig` "does not repeat anything
  else that file already says"; the vocabulary rule says a term is defined
  on first use in the file header. Which wins? If each file defines its own
  terms, must the wording match: _crossing_ is verbatim in both, _view_ is
  not.

- **Naming `module.zig` and `interface.zig`.** `abi.zig` writes
  `src/module.zig` (line 10), `module.zig` (line 46) and `interface.zig`
  (line 6); `module.zig` writes `api/interface.zig` (line 18). The pass used
  `module.zig` for the file and `api/raise.zig`, `runtime/method_type.zig`
  and `value/tables.zig` for the others.

- **Where a callback's own rule lives.** `module.zig`'s `Spec` puts the
  restrictions on `gc`, `gcmark`, `compare` and `hash` in `///` blocks on
  the fields. `abi.zig`'s `AbstractType` has no per-field `///` and says
  everything in the container's block. When does a field get a `///` block
  of its own?

- **A blank line after a group comment.** `module.zig`'s `Spec` has one
  between "// The collector." and the first field; `abi.zig`'s
  `AbstractType` has none.

- **"This function cannot raise."** `module.zig` says it on `Pairs.next`,
  `toAbstract` and `wake`, and omits it on every other non-raising function,
  including `toInteger`, `toKeyword` and the other `to*` siblings of
  `toAbstract`. `abi.zig` lines 1 to 266 declare no function. The pass kept
  it on `Signal.fromWire` and `abstractHead`, where it already stood.

- **"the VM" or "the runtime".** `module.zig` uses both ("the VM that
  provided the result" in `loop`; "the runtime's allocator" in `alloc`).
  `abi.zig` lines 1 to 266 use only "the runtime". The pass used "the
  runtime".

- **What a body `//` comment says.** Ruled on 2026-09-07: it says what the
  next lines do or why they are where they are, in one or two sentences, and
  in an example a reason about one call sits above that call rather than in
  the `///` block. `module.zig`'s `toCString` comment ("Not `bytesView`: it
  answers the empty slice for a null pointer, and an empty slice has nowhere
  to put a sentinel.") is that shape. The rule is in "Comments inside a
  body" above.

- **Enum members.** `abi.zig`'s `FiberStatus` documents its members only in
  the container's block, by bare name ("The additional values are `new` and
  `alive`"). `module.zig` declares no enum, though `Called` writes a member
  as a value with a leading dot (`.ok`). The pass followed `FiberStatus` for
  `Signal`.

- **Private functions.** Only `module.zig` has them. Their blocks keep the
  verb-first sentence and the failure sentence, and in place of the calling
  facts name the callers the function serves (`terminate`: "`nfuns_ext`,
  `getmethod` and `nextmethod` each take a table that ends with a null-name
  row") or why it is the one place (`toCString`: "The one place the sentinel
  is claimed"). None has a ```zig block or a "See" sentence. `abi.zig` has
  nothing to compare against.
