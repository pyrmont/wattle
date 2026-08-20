//! `value_wrap.zig`'s `ops` namespace, resolved to the C symbols instead of the
//! Zig bodies. `build.zig` puts this behind `vm_run.zig`'s `value_wrap` import
//! when `-Dvalue-wrap=c`.
//!
//! It exists for the same reason `vm_calls_extern.zig` does: once the loop
//! imports a subsystem rather than linking against it, the selector has to be
//! honoured by choosing what gets imported, or `-Dvalue-wrap=c` would silently
//! keep answering with Zig for every value the interpreter touches.
//!
//! Every member here is a call where the Zig side has a shift and a compare.
//! In C those are macros in `janet.h`, so the C `run_vm` never pays for them
//! either; this configuration is the only one in the matrix where anybody does.
//! That is the price of asking a C-selected value layer to answer for a Zig
//! loop, and it is charged to the selector rather than to the port.

const abi = @import("abi");
const c = abi.c;

pub const ops = struct {
    pub inline fn checkType(x: c.Janet, t: c.JanetType) bool {
        return c.janet_checktype(x, t) != 0;
    }
    pub inline fn checkTypes(x: c.Janet, typeflags: c_int) bool {
        return c.janet_checktypes(x, typeflags) != 0;
    }
    pub inline fn isNumber(x: c.Janet) bool {
        return c.janet_checktype(x, c.JANET_NUMBER) != 0;
    }
    pub inline fn truthy(x: c.Janet) bool {
        return c.janet_truthy(x) != 0;
    }
    pub inline fn unwrapNumber(x: c.Janet) f64 {
        return c.janet_unwrap_number(x);
    }
    pub inline fn unwrapInteger(x: c.Janet) i32 {
        return c.janet_unwrap_integer(x);
    }
    pub inline fn wrapNumber(d: f64) c.Janet {
        return c.janet_wrap_number(d);
    }
    /// `janet_wrap_integer` is absent from a `-Dnanbox=false` build, which is
    /// the defect `FOUND.md` records against `wrap.c` and which `value_wrap.zig`
    /// reproduces. Spelled out here rather than called, so that this shim does
    /// not need a symbol that configuration does not have.
    pub inline fn wrapInteger(n: i32) c.Janet {
        return c.janet_wrap_number(@floatFromInt(n));
    }
    pub inline fn wrapBoolean(b: bool) c.Janet {
        return c.janet_wrap_boolean(@intFromBool(b));
    }
    pub inline fn wrapNil() c.Janet {
        return c.janet_wrap_nil();
    }
    pub inline fn wrapTrue() c.Janet {
        return c.janet_wrap_true();
    }
    pub inline fn wrapFalse() c.Janet {
        return c.janet_wrap_false();
    }
    pub inline fn wrapFunction(x: [*c]c.JanetFunction) c.Janet {
        return c.janet_wrap_function(x);
    }
    pub inline fn wrapArray(x: [*c]c.JanetArray) c.Janet {
        return c.janet_wrap_array(x);
    }
    pub inline fn wrapTable(x: [*c]c.JanetTable) c.Janet {
        return c.janet_wrap_table(x);
    }
    pub inline fn wrapBuffer(x: [*c]c.JanetBuffer) c.Janet {
        return c.janet_wrap_buffer(x);
    }
    pub inline fn wrapStruct(x: c.JanetStruct) c.Janet {
        return c.janet_wrap_struct(x);
    }
    pub inline fn wrapTuple(x: c.JanetTuple) c.Janet {
        return c.janet_wrap_tuple(x);
    }
    pub inline fn unwrapFunction(x: c.Janet) [*c]c.JanetFunction {
        return c.janet_unwrap_function(x);
    }
    pub inline fn unwrapCFunction(x: c.Janet) c.JanetCFunction {
        return c.janet_unwrap_cfunction(x);
    }
    pub inline fn unwrapFiber(x: c.Janet) [*c]c.JanetFiber {
        return c.janet_unwrap_fiber(x);
    }
};
