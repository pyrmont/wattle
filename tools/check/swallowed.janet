#!/usr/bin/env janet
# Find raising Zig functions that reach a raise through a C-ABI abi.
#
# A abi flattens a raise into a *report*: `janet_vm.c_raised` is set, the
# caller gets a determinate blank value, and whoever opens the next protected
# scope aborts with
#
#     janet abort: a raise was reported across the C ABI and never consumed
#
# That is correct when the caller really is C, and a defect when the caller is a
# Zig function that could have propagated the error itself.  The message names
# neither the abi nor the file, and it surfaces arbitrarily far from the cause,
# which is why every instance found so far was found by accident:
#
#   - Phase 11 Part 12, by a type that would not unify (`vm_calls.fillString`);
#   - Part 13, by an `#ifdef` with no stated reason (`args_core`'s `Wide`);
#   - Part 14, by writing a callback out in full (`peg`'s `pegMarshal`);
#   - Part 15, by running this (`janet_stream`, `janet_loop`, `janet_get`, ...).
#
# `phase_11.md`'s rule 40 is the argument for enumerating the class instead.
#
# ## What counts as an abi
#
# Two constructions, and missing the second is what made Part 14's hand-rolled
# version of this report seven sites instead of eleven:
#
#     export fn janet_x(...) callconv(.c) T { return raise.reported(xImpl(...)); }
#
#     const xAbi = raise.panicking(x).abi;   // `panicking` is `reportToAbi` too
#     comptime { @export(&xAbi, .{ .name = "janet_x" }); }
#
# ## Why it is transitive
#
# A abi's caller need not be the raising function.  `net_sockets.makeStream`
# was a *non-raising helper* around `janet_stream` with four raising callers,
# and `vm_calls.methodToFun` was two levels down from `binopCall`.  So a
# function that reaches an abi and cannot itself propagate is treated as an abi
# in turn, to a fixpoint.
#
# ## Three spellings of the same call
#
# A abi is reached as `c.janet_x(...)` from another file, as a bare
# `janet_x(...)` inside the file that defines it, and -- the one that hid
# `inttypes.zig`'s `Box` for two parts -- through a **comptime alias**:
#
#     const unwrap = if (T == i64) janet_unwrap_s64 else janet_unwrap_u64;
#     ...
#     var acc: u64 = @bitCast(Box(T).unwrap(argv[0]));
#
# Nothing at that call site spells an abi, and `grep c.janet_unwrap_s64` reports
# the file clean.  All three are matched.
#
# ## What consuming the report looks like
#
# Calling an abi from Zig is legitimate when the caller turns the report back
# into an error, and there are three spellings of that:
#
#     try raise.crossing(janet_buffer_push_u8(buffer, byte));   // wrapping
#     _ = c.janet_call(fun, 1, &args);
#     _ = try raise.crossing({});                               // on the next line
#
# Both are recognised, and getting that wrong is most of the difference between
# a report worth reading and a list of six sites of which five are fine.
#
# There was a third -- `const x = raise.declared(sym).call;`, the alias form,
# which consumed the report once rather than at each call.  Phase 11 Part 26
# deleted `raise.declared` along with its last users, the eleven stranded
# `_extern.zig` shims and `dynlib.zig`'s four `util.c` symbols.  The spelling is
# still matched below, at the cost of one `choice` and against the day something
# reintroduces it.
#
# ## What it cannot see
#
# An indirect call.  A abi invoked through a stored function pointer -- an
# `AbstractType` slot, a `JanetMethod` table -- is invisible here, and so is a
# call from C.  It also cannot tell a *deliberate* flattening from a defect, and
# `allow` is how such a site would be silenced with a reason -- it is empty, and
# the note beside it says why the one candidate did not survive examination.

(import ../common :as tools)

# Sites where flattening is the correct answer, because the caller genuinely
# cannot propagate.  Each needs a reason.
#
# Empty, and it is worth saying why rather than leaving a bare `@{}`.  Part 15
# opened this list for `net_sockets.zig`'s two accept callbacks, on the
# assumption that an event-loop callback has nowhere to raise to -- which is the
# argument `abstract_type.zig` makes for `gc` and `gcmark`, and which is *wrong
# for this table*.  `ev_callback.EVCallback` is `raise.Error!void`: the hinge
# typed it raising exactly as it typed `CFunction`, and `acceptWindows`
# had been propagating all along, ten lines from the site being excused.
#
# So the bar for an entry here is high: a callback type that is genuinely
# non-raising, not a guess that one is.
(def allow @{})

(def flattens ["raise.reported" "raise.report(" "reportToAbi" "raise.panicking"])

# Janet's `:w` is alphanumeric and does not include the underscore, so `\w` is
# spelled out.  Every pattern here is one of Python's, translated rather than
# redesigned: this tool's output is the oracle for its own port.
(def- word ~(choice :w "_"))

(def- fn-peg
  (peg/compile
    ~(sequence (capture (any (set " \t")))
               (opt (sequence "pub" :s+))
               (opt (sequence "export" :s+))
               (opt (sequence "inline" :s+))
               "fn" :s+
               (capture (some ,word))
               :s* "(")))

# `@export(&IDENT, .{ .name = "SYM"` -- IDENT may be dotted.
(def- export-named-peg
  (peg/compile
    ~(any (choice
            (sequence "@export(" :s* "&"
                      (capture (some (choice ,word ".")))
                      :s* "," :s* ".{" :s* ".name" :s* "=" :s* "\""
                      (capture (some ,word)) "\"")
            1))))

# `const NAME = raise.SOMETHING(...` up to the end of the line.
(def- raise-bind-peg
  (peg/compile
    ~(any (choice
            (sequence "const" :s+ (capture (some ,word)) :s* "=" :s*
                      (capture (sequence "raise." (some ,word) "(" (any (if-not "\n" 1)))))
            1))))

# `const NAME = <anything up to a semicolon>;`
(def- const-peg
  (peg/compile
    ~(any (choice
            (sequence "const" :s+ (capture (some ,word)) :s* "=" :s*
                      (capture (any (if-not (set ";\n") 1))) ";")
            1))))

# A PEG built from a symbol name is compiled on every call unless it is kept,
# and these run over every function body once per fixpoint pass. Python's `re`
# caches compiled patterns by their source string and this is the same idea
# made explicit; without it the sweep does not finish.
(def- peg-cache @{})

(defn- cached [kind sym make]
  (def key [kind sym])
  (or (get peg-cache key)
      (let [compiled (peg/compile (make))]
        (put peg-cache key compiled)
        compiled)))

(defn- reads-word?
  "Whether `text` names `sym` as a whole word, not preceded by a word char or dot."
  [text sym]
  (and (string/find sym text)
       (truthy? (peg/find (cached :word sym
                                  |~(sequence (not (look -1 (choice ,word ".")))
                                              ,sym (not ,word)))
                          text))))

(defn- calls?
  "Whether `text` calls `sym`, per one of the three spellings.

  `dotted` allows a leading `.`, which is how an alias reached as a struct
  member is spelled at the call site."
  [text sym &opt dotted]
  (and (string/find sym text)
       (truthy?
         (peg/find (if dotted
                     (cached :dotted sym
                             |~(sequence (not (look -1 ,word)) (opt ".") ,sym :s* "("))
                     (cached :bare sym
                             |~(sequence (not (look -1 (choice ,word "."))) ,sym :s* "(")))
                   text))))

(defn- calls-c? [text sym]
  (and (string/find (string "c." sym) text)
       (truthy? (peg/find (cached :c sym
                                  |~(sequence (not (look -1 ,word)) "c." ,sym :s* "("))
                          text))))

(defn- functions
  "Every function in one file as [name raising body line]."
  [text]
  (def lines (string/split "\n" text))
  (def out @[])
  (for i 0 (length lines)
    (when-let [caps (peg/match fn-peg (lines i))]
      (def indent (caps 0))
      (def name (caps 1))
      # The signature may wrap; gather until the opening brace.
      (var sig (lines i))
      (var j (+ i 1))
      (while (and (not (string/find "{" sig)) (< j (length lines)))
        (set sig (string sig " " (string/trim (lines j))))
        (++ j))
      # `error{JanetSignal}!` spelled out counts too. `interop.zig` writes it
      # that way on purpose -- the Zig client is not the runtime's module and
      # does not import `raise` -- so every cfunction in that file read as
      # non-raising and none of its calls could ever be reported. A tool that
      # recognises one spelling of a thing polices the files that use that
      # spelling, which is not the population it claims.
      (def raising (or (truthy? (string/find "raise.Error!" sig))
                       (truthy? (string/find "error{JanetSignal}!" sig))))
      # The body runs to the first line that closes at the same indent.
      (def body @[])
      (var k (- j 1))
      (def closer (string indent "}"))
      (var done false)
      (while (and (not done) (< k (length lines)))
        (array/push body (lines k))
        (if (= (string/trimr (lines k)) closer) (set done true) (++ k)))
      (array/push out [name raising (string/join body "\n") (+ i 1)])))
  out)

(defn- abis
  "Every C symbol whose definition flattens a raise."
  [sources]
  (def found @{})
  (eachp [_ text] sources
    (each [name _ body _] (functions text)
      (when (and (or (string/has-prefix? "janet_" name)
                     (string/has-suffix? "Abi" name))
                 (some |(string/find $ body) flattens))
        (put found name true)))
    # `const xAbi = raise.panicking(x).abi;` then `@export(&xAbi, ...)`.
    (def binds @{})
    (def bind-caps (peg/match raise-bind-peg text))
    (var i 0)
    (while (< i (length bind-caps))
      (put binds (bind-caps i) (bind-caps (+ i 1)))
      (+= i 2))
    (def export-caps (peg/match export-named-peg text))
    (var j 0)
    (while (< j (length export-caps))
      (def ident (first (string/split "." (export-caps j))))
      (def sym (export-caps (+ j 1)))
      (def rhs (get binds ident ""))
      (when (some |(string/find $ rhs) flattens)
        (put found sym true))
      (+= j 2)))
  found)

(defn main [& argv]
  (def quiet (has-value? argv "--quiet"))
  (os/cd tools/root)

  (def paths @[])
  (defn walk [dir]
    (each entry (sort (os/dir dir))
      (def path (string dir "/" entry))
      (case (os/stat path :mode)
        :directory (walk path)
        :file (when (string/has-suffix? ".zig" entry) (array/push paths path)))))
  (each d tools/src-dirs (walk d))
  (array/push paths "src/root.zig")
  (sort paths)

  (def sources @{})
  (each path paths (put sources path (slurp path)))

  (def abi-names (abis sources))
  (unless quiet
    (print (length abi-names) " C-ABI abis flatten a raise into a report"))
  (when (has-value? argv "--names")
    (each n (sort (keys abi-names)) (print "ABI " n)))

  # A call to any of these flattens, unless the caller can propagate.
  # Every name a caller can reach a flattening definition by.
  #
  # Until Phase 13 increment 8e a runtime function that flattened a raise and
  # the C symbol `capi.zig` published it under were the same string, so one set
  # served both the `c.NAME(` call sites and the bare in-file ones. 8e gave the
  # runtime function a domain name and left the published spelling in the
  # manifest, and the two are now different: `c.janet_array_push(...)` reaches
  # `value/arrays.pushAbi`. Matching call sites against the Zig names alone
  # dropped seventeen callers out of `flat-local` at a stroke -- not because
  # they stopped reaching an abi, but because the tool stopped recognising the
  # name they reach it by.
  #
  # So the set is both: the Zig names, and every symbol `capi.zig` exports
  # whose target is one of them.
  (def flattening (merge @{} abi-names))
  (let [capi (get sources "src/runtime/capi.zig" "")]
    (def target @{})                   # capi entry point -> the impl name it calls
    (var prev nil)
    (each line (string/split "\n" capi)
      (when-let [m (peg/match ~(sequence "pub fn " (capture (some (choice :w "_"))) "(") line)]
        (set prev (first m)))
      (when-let [m (peg/match ~(sequence (any (choice " " "\t")) (opt "return ") "impl." (some (choice :w "_")) "." (capture (some (choice :w "_"))) "(") line)]
        (when prev (put target prev (first m)) (set prev nil))))
    (each line (string/split "\n" capi)
      # Two spellings, because `capi.zig` has two. An entry point declared in
      # that file is `@export(&entry, .{ .name = "sym" })`; a target exported
      # directly states its signature in the same call, as
      # `publish("sym", &impl.mod.fn, fn (...) ...)`.
      (def m (or (peg/match ~(sequence (thru "@export(&") (capture (some (choice :w "_" "." "(" ")")))
                                       (thru ".name = \"") (capture (some (choice :w "_")))) line)
                 (when-let [p (peg/match ~(sequence (thru "publish")
                                                    (any (choice "Hidden"))
                                                    "(\"" (capture (some (choice :w "_"))) "\"" :s* "," :s* "&"
                                                    (capture (some (choice :w "_" "." "(" ")")))) line)]
                   [(p 1) (p 0)])))
      (when m
        (def [ref sym] m)
        (def zig (cond
                   # **A generated getter's flattening half is `.abi`, and its
                   # last component says nothing.** `impl.args.GetString.abi`
                   # resolved to `abi`, which is in no set, so the exported
                   # symbol was never added to the flattening set at all --
                   # `janet_getstring` and its fifteen siblings among them. The
                   # `.abi` member *is* the convention: `raise.panicking(f).abi`
                   # and every `Get*`/`Opt*` generic name their flattening half
                   # that way and nothing else does. So the suffix is what
                   # classifies, and the name inside the generic (`IndexAbi`,
                   # `CountAbi`) never has to be reached.
                   (string/has-suffix? ".abi" ref) :generated
                   (string/find "." ref) (last (string/split "." ref))
                   (get target ref ref)))
        (when (or (= zig :generated) (get abi-names zig))
          (put flattening sym true)))))
  (def local @{})                      # [path fn] -> [body raising line]

  # The eleven stranded `_extern.zig` shims were skipped here, because each
  # was the untaken branch of a comptime `if` that Zig never analyses -- and
  # skipping them is exactly why nothing noticed that one of them had stopped
  # compiling.  Part 26 deleted all eleven; `phase_11.md`'s rule 72 is what
  # that silence cost, and rule 73 the two probes that would have read them.
  (eachp [path text] sources
    (each [name raising body line] (functions text)
      (put local [path name] [body raising line])))

  # `const NAME = <abi>;` and `const NAME = if (..) <abi> else <abi>;`,
  # which is how `inttypes.zig` reached one without naming it at the call
  # site. The alias may be a struct member, so `.NAME(` counts as well.
  (def aliases @{})
  (eachp [path text] sources
    (def caps (peg/match const-peg text))
    (var i 0)
    (while (< i (length caps))
      (def name (caps i))
      (def rhs (caps (+ i 1)))
      (+= i 2)
      (unless (or (string/find "raise.declared" rhs) (string/find "raise.crossing" rhs))
        (eachk sym flattening
          (when (reads-word? rhs sym)
            (put aliases path (put (get aliases path @{}) name sym)))))))

  (def defines-cache @{})
  (defn defines [path sym]
    (def key [path sym])
    (when (nil? (get defines-cache key))
      (put defines-cache key
           (truthy? (peg/find (cached :export sym
                                      |~(sequence "export fn " ,sym :s* "("))
                              (sources path)))))
    (get defines-cache key))

  (defn consumed
    "Whether this call's report is turned back into an error."
    [body call]
    (def lines (string/split "\n" body))
    (var answer true)
    (for i 0 (length lines)
      (def line (lines i))
      (when (and answer (string/find call line))
        (cond
          # `try raise.crossing(<call>)` on the same line.
          (or (string/find "raise.crossing" line) (string/find "raise.declared" line))
          nil
          # `try crossing(<call>)` -- the undotted spelling a file that
          # cannot import `raise` writes for itself. Recognising only the
          # dotted one would report every call in such a file.
          (string/find "try crossing(" line)
          nil
          # `_ = try raise.crossing({});` on the next non-blank line, which
          # is how `pp_format.dynprintf` consumes `janet_call`'s.
          (and (< (+ i 1) (length lines))
               (or (string/find "raise.crossing" (lines (+ i 1)))
                   (string/find "try crossing(" (lines (+ i 1)))))
          nil
          (set answer false))))
    answer)

  (var flat-local @{})

  (defn reaches [body path]
    (var found nil)
    (eachk sym flattening
      (unless found
        # `c.janet_x(...)` from anywhere, or a bare `janet_x(...)` in the
        # file that defines it.
        (when (and (calls-c? body sym)
                   (not (consumed body (string "c." sym "("))))
          (set found sym))
        (when (and (not found) (string/find sym body) (defines path sym)
                   (calls? body sym)
                   (not (consumed body (string sym "("))))
          (set found sym))))
    (unless found
      (eachp [name sym] (get aliases path @{})
        (when (and (not found) (calls? body name true)
                   (not (consumed body (string name "("))))
          (set found (string name " (= " sym ")")))))
    (unless found
      # A abi is a local function too, in the file that defines it; the
      # first branch has already judged those, with the `consumed` test
      # this one also needs.
      (eachk key flat-local
        (def [p fname] key)
        (when (and (not found) (= p path) (not (get flattening fname))
                   (calls? body fname)
                   (not (consumed body (string fname "("))))
          (set found fname))))
    found)

  # Fixpoint over non-raising local helpers that reach an abi.
  (var changed true)
  (while changed
    (set changed false)
    (eachp [key value] local
      (def [body raising _] value)
      (unless (or raising (get flat-local key) (get allow key))
        (when (reaches body (key 0))
          (put flat-local key true)
          (set changed true)))))

  (def findings @[])
  (each key (sort (keys local))
    (def [body raising line] (local key))
    (def [path fname] key)
    (when (and raising (not (get allow key)))
      (when-let [via (reaches body path)]
        (array/push findings [path line fname via]))))

  (unless quiet
    (print (length flat-local) " non-raising local helpers flatten one on their behalf")
    (when (has-value? argv "--names")
      (each k (sort (keys flat-local)) (print "LOCAL " (k 0) " " (k 1))))
    (print))
  (each [path line fname via] findings
    (print path ":" line "  " fname "() is raising and reaches a report via " via))
  (when (empty? findings)
    (print "no raising caller reaches a report"))
  (os/exit (if (empty? findings) 0 1)))
