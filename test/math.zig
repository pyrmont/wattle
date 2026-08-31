//! Behavioral contract for Janet's random number generator and the two
//! integer-math kernels behind `math/gcd` and `math/lcm`.
//!
//! ## Every vector is exact, because the state is marshalled
//!
//! A `math/rng` survives `marshal`/`unmarshal` bit for bit, so its output is
//! not a statistical property that a port may approximate — it is a format.
//! Two Janet programs, or one program and an image written by an older build,
//! have to agree on every word. So the assertions below are literal sequences
//! rather than distribution checks, and the post-seed state is pinned as well
//! as the draws.
//!
//! That is also why `sameDouble` compares bits rather than values: `-0.0` and
//! NaN both matter here, and `==` would let either through.
//!
//! ## The seeding has three cases the suites cannot reach
//!
//! Seeding runs sixteen warmup draws, so the post-seed state is not the seed.
//! A long seed **folds by XOR into sixteen bytes**, so a twenty-byte input and
//! a carefully chosen different twenty-byte input reach the same state — and
//! an all-zero state forces `a` to 1, which is the branch that stops the
//! generator producing nothing but zeros forever. Reaching that from Janet
//! means finding a seed string that cancels, which nothing does by accident.
//!
//! ## Why `math/gcd` is called rather than compiled
//!
//! A NaN argument written as a Janet literal is folded into a constant slot,
//! and `janetc_loadconst` casts such a constant to `int32_t` without excluding
//! NaN first — `FOUND.md` has that defect, unresolved. Calling the cfunction
//! avoids the compiler entirely, so these vectors do not depend on it.

const std = @import("std");
const types = @import("types");
const repr = @import("repr");
const c = @import("cabi");
const harness = @import("harness.zig");
const core_env = @import("subsystems").env;
const math = @import("subsystems").math;
const wrap = @import("subsystems").value.wrap;
const vm_lifecycle = @import("subsystems").lifecycle;

/// `janet_rng_longseed`, reached as the C entry point rather than as
/// `math.rngLongseed`.
///
/// The Zig function takes a `[]const u8`, so the negative length the contract
/// below pins cannot be handed to it. The published signature still takes an
/// `int32_t`, `capi.zig`'s `cbytes` is what turns a negative one into an empty
/// range, and this is the declaration that lets the assertion reach it. One
/// line here rather than in `harness.internal`,
/// because nothing else needs it -- the same call `test/fiber_core.zig`
/// records about its private copy of the frame macros.
extern fn janet_rng_longseed(rng: *types.JanetRNG, bytes: [*]const u8, len: i32) callconv(.c) void;

fn sameDouble(a: f64, b: f64) bool {
    return @as(u64, @bitCast(a)) == @as(u64, @bitCast(b));
}

fn expectSequence(rng: *types.JanetRNG, expected: []const u32) void {
    for (expected) |word| std.debug.assert(math.rngU32(rng) == word);
}

fn expectState(rng: *const types.JanetRNG, a: u32, b: u32, d: u32, e: u32) void {
    std.debug.assert(rng.a == a);
    std.debug.assert(rng.b == b);
    std.debug.assert(rng.c == d);
    std.debug.assert(rng.d == e);
}

const from_zero = [_]u32{
    0x7cb7e804, 0x5cc33daa, 0xe9aa2ab6, 0x6ce3abcb,
    0x0f68de54, 0x3ce19a65, 0x8faa2224, 0xe4c19f5b,
};

fn theSeed() void {
    var rng: types.JanetRNG = undefined;

    // Sixteen warmup draws, so the post-seed state is not the seed constants.
    math.rngSeed(&rng, 0);
    expectState(&rng, 0x0c1a42aa, 0xeae5edce, 0x4f5fd051, 0xbf7df883);
    std.debug.assert(rng.counter == 0x00587c50);
    expectSequence(&rng, &from_zero);

    math.rngSeed(&rng, 0xDEADBEEF);
    expectState(&rng, 0xbbf082e8, 0xa4ecbbdc, 0xceeb0ecf, 0xd9874a93);
    expectSequence(&rng, &.{ 0x35310846, 0x7e749c7f, 0x09e1b927, 0x2255b762 });

    // Reseeding is a full reset: the counter does not carry over.
    math.rngSeed(&rng, 0);
    std.debug.assert(rng.counter == 0x00587c50);
    expectSequence(&rng, &from_zero);
}

fn theLongSeed() void {
    var rng: types.JanetRNG = undefined;
    var empty: types.JanetRNG = undefined;

    math.rngLongseed(&rng, "janet");
    expectState(&rng, 0x3c6c72fb, 0xfadea204, 0xd01b463f, 0xbaf55482);
    std.debug.assert(rng.counter == 0x00587c50);
    expectSequence(&rng, &.{ 0x46d163c2, 0x0dc3a987, 0x9843ec91, 0xc05d8081 });

    // Input longer than sixteen bytes folds by XOR into the state.
    math.rngLongseed(&rng, "abcdefghijklmnopqrst");
    expectState(&rng, 0x4cf87e6f, 0x9fca16c7, 0xe2ce039b, 0x603634b8);

    // An empty seed leaves the state all zeros, so `a` is forced to 1.
    math.rngLongseed(&empty, "");
    expectState(&empty, 0x9c5f0f15, 0x094111e2, 0xcd5101c1, 0x0c55143a);

    // Bytes that cancel under the fold reach that same forced state — which is
    // the only way to show the forcing is about the folded value rather than
    // about the input being empty.
    const cancels = [20]u8{ 1, 2, 3, 4, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 2, 3, 4 };
    math.rngLongseed(&rng, &cancels);
    expectState(&rng, empty.a, empty.b, empty.c, empty.d);

    // A negative length reads nothing rather than walking backwards. Through
    // the C entry point: see the declaration above.
    janet_rng_longseed(&rng, "janet", -1);
    expectState(&rng, empty.a, empty.b, empty.c, empty.d);
}

fn theDoubleDraw() void {
    var rng: types.JanetRNG = undefined;

    math.rngSeed(&rng, 7);
    std.debug.assert(sameDouble(math.rngDouble(&rng), 0.012130103775150669));
    std.debug.assert(sameDouble(math.rngDouble(&rng), 0.95069094881030836));
    std.debug.assert(sameDouble(math.rngDouble(&rng), 0.39906010130019998));

    // Every draw stays in [0, 1).
    math.rngSeed(&rng, 11);
    for (0..2000) |_| {
        const x = math.rngDouble(&rng);
        std.debug.assert(x >= 0.0 and x < 1.0);
    }

    // And consumes exactly two 32-bit words, which is what makes a marshalled
    // generator resumable at the same point.
    var paired: types.JanetRNG = undefined;
    var stepped: types.JanetRNG = undefined;
    math.rngSeed(&paired, 11);
    math.rngSeed(&stepped, 11);
    _ = math.rngDouble(&paired);
    _ = math.rngU32(&stepped);
    _ = math.rngU32(&stepped);
    expectState(&paired, stepped.a, stepped.b, stepped.c, stepped.d);
    std.debug.assert(paired.counter == stepped.counter);
}

/// `math/seedrandom` and `math/random` run on one shared generator, and it is
/// the same object every time it is asked for.
///
/// It used to assert that the generator is not null. That assertion went with
/// the call: `janet_default_rng` was declared `[*c]JanetRNG`, so the pointer
/// arrived maybe-null and the test was the check; `math.defaultRng` returns
/// `*JanetRNG` and Zig will not let it be null. `DESIGN.md` §3 -- the property
/// stopped being an agreement and became a construction.
fn theDefaultRng() void {
    const shared = math.defaultRng();

    math.rngSeed(shared, 0);
    std.debug.assert(math.rngU32(shared) == 0x7cb7e804);
    std.debug.assert(math.defaultRng() == shared);
}

// ------------------------------------------------------------- gcd and lcm

fn call2(fun: anytype, a: f64, b: f64) !f64 {
    var argv = [2]repr.Value{ wrap.fromNumber(a), wrap.fromNumber(b) };
    return wrap.toNumber(try fun(argv[0..2]));
}

fn theGcdAndLcm() !void {
    const gcd = harness.core("math/gcd");
    const lcm = harness.core("math/lcm");
    const inf = std.math.inf(f64);
    const nan = std.math.nan(f64);

    std.debug.assert(sameDouble(try call2(gcd, 12, 18), 6.0));
    std.debug.assert(sameDouble(try call2(gcd, 0, 5), 5.0));
    std.debug.assert(sameDouble(try call2(gcd, 5, 0), 5.0));
    std.debug.assert(sameDouble(try call2(gcd, 0, 0), 0.0));
    std.debug.assert(sameDouble(try call2(gcd, 7, 13), 1.0));
    // Not restricted to integers.
    std.debug.assert(sameDouble(try call2(gcd, 2.5, 1.25), 1.25));

    // `fmod` keeps the sign of the dividend, so negative inputs propagate and
    // the result is not always positive.
    std.debug.assert(sameDouble(try call2(gcd, -12, 18), 6.0));
    std.debug.assert(sameDouble(try call2(gcd, 12, -18), -6.0));
    std.debug.assert(sameDouble(try call2(gcd, -12, -18), -6.0));

    std.debug.assert(sameDouble(try call2(lcm, 12, 18), 36.0));
    std.debug.assert(sameDouble(try call2(lcm, 0, 5), 0.0));
    std.debug.assert(sameDouble(try call2(lcm, -12, 18), -36.0));
    std.debug.assert(sameDouble(try call2(lcm, 12, -18), 36.0));
    std.debug.assert(sameDouble(try call2(lcm, 7, 13), 91.0));
    std.debug.assert(sameDouble(try call2(lcm, 2.5, 1.25), 2.5));

    // Any infinite operand makes the gcd positive infinity whatever its sign,
    // and makes the lcm NaN.
    std.debug.assert(sameDouble(try call2(gcd, inf, 4), inf));
    std.debug.assert(sameDouble(try call2(gcd, 4, inf), inf));
    std.debug.assert(sameDouble(try call2(gcd, -inf, 4), inf));
    std.debug.assert(sameDouble(try call2(gcd, 4, -inf), inf));
    std.debug.assert(std.math.isNan(try call2(lcm, inf, 4)));
    std.debug.assert(std.math.isNan(try call2(lcm, 4, inf)));

    // NaN in, NaN out — and `lcm(0, 0)` is NaN rather than zero, because it
    // divides by the gcd.
    std.debug.assert(std.math.isNan(try call2(gcd, nan, 4)));
    std.debug.assert(std.math.isNan(try call2(gcd, 4, nan)));
    std.debug.assert(std.math.isNan(try call2(gcd, nan, nan)));
    std.debug.assert(std.math.isNan(try call2(lcm, nan, 4)));
    std.debug.assert(std.math.isNan(try call2(lcm, 0, 0)));
}

// -------------------------------------------------------- the Janet surface

var environment: *types.JanetTable = undefined;

fn eval(source: [*:0]const u8) repr.Value {
    var result: repr.Value = undefined;
    std.debug.assert(core_env.dostring(environment, source, "math-contract", &result) == 0);
    return result;
}

fn truthy(source: [*:0]const u8) void {
    std.debug.assert(repr.truthy(eval(source)));
}

fn theRngInt() void {
    // A zero bound short-circuits before drawing.
    const zeroes = wrap.toTuple(eval(
        "(let [r (math/rng 5)] [(math/rng-int r 0) (math/rng-int r 0)])",
    ));
    std.debug.assert(wrap.toNumber(zeroes[0]) == 0.0);
    std.debug.assert(wrap.toNumber(zeroes[1]) == 0.0);

    // Without a bound the draw is a 31-bit word: the top bit is discarded.
    std.debug.assert(wrap.toNumber(eval("(let [r (math/rng 0)] (math/rng-int r))")) ==
        @as(f64, @floatFromInt(from_zero[0] >> 1)));

    // A bound of 1 always yields 0, and consumes exactly one word per call
    // because every draw falls inside the acceptance window — which the third
    // element proves by being the *third* word of the sequence.
    const bounded = wrap.toTuple(eval(
        "(let [r (math/rng 0)] [(math/rng-int r 1) (math/rng-int r 1) (math/rng-int r)])",
    ));
    std.debug.assert(wrap.toNumber(bounded[0]) == 0.0);
    std.debug.assert(wrap.toNumber(bounded[1]) == 0.0);
    std.debug.assert(wrap.toNumber(bounded[2]) ==
        @as(f64, @floatFromInt(from_zero[2] >> 1)));

    // Bounds are respected, and a fixed seed gives a fixed sequence.
    truthy(
        \\(let [r (math/rng 42)]
        \\  (all |(and (>= $ 0) (< $ 10)) (seq [_ :range [0 500]] (math/rng-int r 10))))
    );
    truthy(
        \\(deep= (seq [_ :range [0 20]] (math/rng-int (math/rng 3) 1000))
        \\       (seq [_ :range [0 20]] (math/rng-int (math/rng 3) 1000)))
    );
}

fn theRngBuffer() void {
    // A length that is not a multiple of four takes the low bytes of a final
    // partial word, which is the only place the tail handling is visible.
    const buffer = wrap.toBuffer(eval("(math/rng-buffer (math/rng 3) 11)"));
    const expected = [11]u8{ 0x20, 0xf8, 0x5a, 0x58, 0xcc, 0x1f, 0x5f, 0x10, 0x76, 0x3b, 0x1c };
    std.debug.assert(buffer.*.count == 11);
    std.debug.assert(std.mem.eql(u8, buffer.*.slice()[0..11], &expected));

    // Zero bytes draws nothing and leaves the generator untouched.
    truthy(
        \\(let [r (math/rng 3)]
        \\  (math/rng-buffer r 0)
        \\  (deep= (math/rng-buffer r 11) (math/rng-buffer (math/rng 3) 11)))
    );

    // An explicit buffer is appended to and returned.
    truthy(
        \\(let [b (buffer "xy")]
        \\  (and (= b (math/rng-buffer (math/rng 3) 4 b))
        \\       (= 6 (length b))
        \\       (= "xy" (string/slice b 0 2))))
    );

    // Every length from 0 to 16 produces exactly that many bytes.
    truthy("(all |(= $ (length (math/rng-buffer (math/rng 1) $))) (range 17))");
}

/// The state survives marshalling exactly, which is what makes every vector
/// above a format rather than an implementation detail.
fn theMarshalRoundTrip() void {
    truthy(
        \\(let [r (math/rng 12345)]
        \\  (math/rng-int r)
        \\  (let [c (unmarshal (marshal r))]
        \\    (deep= (seq [_ :range [0 8]] (math/rng-int r))
        \\           (seq [_ :range [0 8]] (math/rng-int c)))))
    );
}

pub fn run() void {
    harness.init();
    environment = harness.coreEnv();

    theSeed();
    theLongSeed();
    theDoubleDraw();
    theDefaultRng();
    theGcdAndLcm() catch @panic("math: a kernel raised unexpectedly");
    theRngInt();
    theRngBuffer();
    theMarshalRoundTrip();

    vm_lifecycle.deinit();
}
