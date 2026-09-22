//! A pseudo-terminal harness: runs a command behind a pty, types at it, and
//! prints what it drew.
//!
//! `build.zig` installs this as `<prefix>/test/wattle-pty` on POSIX targets
//! other than wasm, and passes its path to `test/suite-lineedit.wattle`, which
//! does the asserting.
//!
//!     wattle-pty -w 'repl:1:> ' -i '(+ 1 2)\r' -- zig-out/bin/wattle -q
//!
//! ## Options
//!
//! - `-w marker` waits for `marker` in the output before any input is sent.
//!   A line editor that has not yet set raw mode discards what it is sent, so
//!   input waits for output rather than for a duration.
//!
//! - `-i input` is typed. `\n`, `\r`, `\t`, `\e`, `\\` and `\xHH` name bytes.
//!   `\m{text}` sends nothing, and waits for `text` in the output after the
//!   last marker found. `\w{N}` and `\h{N}` resize the terminal to `N`
//!   columns or rows once the output has been quiet, since a resize sent with
//!   the keystrokes races the redraw.
//!
//! - `-c` and `-r` are the terminal's columns and rows, 100 and 30 by
//!   default. `-q` is how many milliseconds of quiet end a read, 300 by
//!   default, and `-t` is the most milliseconds any wait takes, 10000.
//!
//! - `-s` prints the screen rather than the bytes, and `-k` with it prints
//!   the cursor after the screen, as `@row,column` counted from 0.
//!
//! - `-x` waits for the command to exit, up to the `-t` limit and before the
//!   pty is closed, and prints two lines after the output. The first is
//!   `@exit N` with the exit status, `@signal N` when a signal ended the
//!   command, or `@running`. The second is `@modes` followed by whichever of
//!   `echo` and `icanon` are set on the terminal, read from the master.
//!
//! ## Output
//!
//! Without `-s`, the output is every byte the command wrote after the `-w`
//! marker was found, escape sequences included. Reading ends after the
//! command has been quiet for the `-q` period, because a pty master reports
//! the command's exit as `EIO` rather than as end of file.
//!
//! With `-s`, every byte the command wrote is applied to a model of a
//! terminal, and the rows are printed, each with its trailing blanks removed
//! and followed by a newline. Rows after the last with anything on it are not
//! printed. The model applies printable runes with an automatic wrap at the
//! last column, CR, LF, BS, TAB, and the CSI sequences for cursor up, down,
//! forward, back and position, erase in line and erase in display. Every
//! other sequence, SGR among them, is applied as nothing. Every rune is one
//! cell wide.
//!
//! After the reading ends, the master is closed, which is end of input to
//! the command, and the command is given the `-t` period to exit before it is
//! killed. The status is 0, or 1 when a marker never appears.

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");
const builtin = @import("builtin");

// ==========================================================================
// Constants
// ==========================================================================

/// The allocator every buffer here uses.
const allocator = std.heap.c_allocator;

/// `TIOCSCTTY`, which makes the slave the child's controlling terminal, and
/// `TIOCSWINSZ`, which sets a terminal's size. The standard library does not
/// declare either for Darwin, where they are `_IO('t', 97)` and `_IOW('t',
/// 103, struct winsize)`, as on the BSDs. `ioctl` takes a `c_int`, so the
/// second is reinterpreted rather than converted.
const tiocsctty: c_int = if (@hasDecl(std.c.T, "IOCSCTTY")) std.c.T.IOCSCTTY else 0x20007461;
const tiocswinsz: c_int = if (@hasDecl(std.c.T, "IOCSWINSZ")) @bitCast(@as(u32, std.c.T.IOCSWINSZ)) else @bitCast(@as(u32, 0x80087467));

// ==========================================================================
// Types
// ==========================================================================

/// One step of the input: bytes to send, text to wait for, or a resize.
const Step = union(enum) {
    send: []const u8,
    wait: []const u8,
    columns: u16,
    rows: u16,
};

/// The options the command line sets.
const Options = struct {
    marker: ?[]const u8 = null,
    input: []const u8 = "",
    columns: u16 = 100,
    rows: u16 = 30,
    quiet: i64 = 300,
    limit: i64 = 10000,
    screen: bool = false,
    cursor: bool = false,
    exit: bool = false,
    command: []const [*:0]const u8 = &.{},
};

/// The bytes the command has written, and how far into them the next wait
/// searches.
const Capture = struct {
    bytes: std.ArrayList(u8) = .empty,
    searched: usize = 0,
};

/// A model of a terminal's screen, which `apply` updates byte by byte.
///
/// `cells` has `rows` rows of `columns` cells, 0 for a blank one. `row` and
/// `column` are the cursor, and `pending` is whether a rune was written in
/// the last column and the wrap has not happened yet.
const Screen = struct {
    columns: usize,
    rows: usize,
    cells: []u21,
    row: usize = 0,
    column: usize = 0,
    pending: bool = false,
    state: enum { ground, escape, csi } = .ground,
    parameters: [32]u8 = undefined,
    count: usize = 0,
    utf8: [4]u8 = undefined,
    utf8_len: usize = 0,
    utf8_want: usize = 0,

    fn init(columns: usize, rows: usize) !Screen {
        const cells = try allocator.alloc(u21, columns * rows);
        @memset(cells, 0);
        return .{ .columns = columns, .rows = rows, .cells = cells };
    }

    /// Applies one byte the command wrote.
    fn apply(screen: *Screen, byte: u8) void {
        switch (screen.state) {
            .escape => {
                if (byte == '[') {
                    screen.state = .csi;
                    screen.count = 0;
                } else {
                    screen.state = .ground;
                }
                return;
            },
            .csi => {
                if (byte >= 0x40 and byte <= 0x7e) {
                    screen.state = .ground;
                    screen.csi(byte, screen.parameters[0..@min(screen.count, screen.parameters.len)]);
                } else if (screen.count < screen.parameters.len) {
                    screen.parameters[screen.count] = byte;
                    screen.count += 1;
                }
                return;
            },
            .ground => {},
        }
        if (screen.utf8_want > 0) {
            screen.utf8[screen.utf8_len] = byte;
            screen.utf8_len += 1;
            if (screen.utf8_len < screen.utf8_want) return;
            screen.utf8_want = 0;
            const codepoint = std.unicode.utf8Decode(screen.utf8[0..screen.utf8_len]) catch 0xfffd;
            screen.put(codepoint);
            return;
        }
        switch (byte) {
            0x1b => screen.state = .escape,
            '\r' => {
                screen.column = 0;
                screen.pending = false;
            },
            '\n' => {
                screen.pending = false;
                screen.lineFeed();
            },
            0x08 => {
                screen.pending = false;
                if (screen.column > 0) screen.column -= 1;
            },
            '\t' => screen.column = @min(screen.columns - 1, (screen.column / 8 + 1) * 8),
            0x00...0x07, 0x0b...0x0c, 0x0e...0x1a, 0x1c...0x1f, 0x7f => {},
            else => {
                const len = std.unicode.utf8ByteSequenceLength(byte) catch {
                    screen.put(0xfffd);
                    return;
                };
                if (len == 1) return screen.put(byte);
                screen.utf8[0] = byte;
                screen.utf8_len = 1;
                screen.utf8_want = len;
            },
        }
    }

    /// Applies a CSI sequence with final byte `final`.
    fn csi(screen: *Screen, final: u8, parameters: []const u8) void {
        var numbers: [2]usize = .{ 0, 0 };
        var index: usize = 0;
        var private = false;
        for (parameters) |p| {
            switch (p) {
                '0'...'9' => if (index < 2) {
                    numbers[index] = numbers[index] * 10 + (p - '0');
                },
                ';' => index += 1,
                else => private = true,
            }
        }
        if (private) return;
        const n = @max(numbers[0], 1);
        switch (final) {
            'A' => screen.row -|= n,
            'B' => screen.row = @min(screen.rows - 1, screen.row + n),
            'C' => screen.column = @min(screen.columns - 1, screen.column + n),
            'D' => screen.column -|= n,
            'H', 'f' => {
                screen.row = @min(screen.rows - 1, @max(numbers[0], 1) - 1);
                screen.column = @min(screen.columns - 1, @max(numbers[1], 1) - 1);
            },
            'K' => switch (numbers[0]) {
                0 => @memset(screen.line(screen.row)[screen.column..], 0),
                1 => @memset(screen.line(screen.row)[0 .. screen.column + 1], 0),
                else => @memset(screen.line(screen.row), 0),
            },
            'J' => switch (numbers[0]) {
                0 => @memset(screen.cells[screen.row * screen.columns + screen.column ..], 0),
                1 => @memset(screen.cells[0 .. screen.row * screen.columns + screen.column + 1], 0),
                else => @memset(screen.cells, 0),
            },
            else => return,
        }
        screen.pending = false;
    }

    /// Returns row `r`'s cells.
    fn line(screen: *Screen, r: usize) []u21 {
        return screen.cells[r * screen.columns ..][0..screen.columns];
    }

    /// Moves the cursor down a row, scrolling at the last.
    fn lineFeed(screen: *Screen) void {
        if (screen.row + 1 < screen.rows) {
            screen.row += 1;
            return;
        }
        std.mem.copyForwards(u21, screen.cells, screen.cells[screen.columns..]);
        @memset(screen.line(screen.rows - 1), 0);
    }

    /// Writes one rune at the cursor.
    fn put(screen: *Screen, codepoint: u21) void {
        if (screen.pending) {
            screen.column = 0;
            screen.lineFeed();
            screen.pending = false;
        }
        screen.line(screen.row)[screen.column] = codepoint;
        if (screen.column + 1 < screen.columns) {
            screen.column += 1;
        } else {
            screen.pending = true;
        }
    }

    /// Prints the rows as the header describes.
    fn print(screen: *Screen, out: *std.ArrayList(u8)) !void {
        var last: usize = 0;
        for (0..screen.rows) |r| {
            for (screen.line(r)) |cell| {
                if (cell != 0) last = r + 1;
            }
        }
        for (0..last) |r| {
            const cells = screen.line(r);
            var end = cells.len;
            while (end > 0 and (cells[end - 1] == 0 or cells[end - 1] == ' ')) end -= 1;
            for (cells[0..end]) |cell| {
                var encoded: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(if (cell == 0) ' ' else cell, &encoded) catch 1;
                try out.appendSlice(allocator, encoded[0..len]);
            }
            try out.append(allocator, '\n');
        }
    }
};

// ==========================================================================
// Public functions
// ==========================================================================

pub fn main(init: std.process.Init.Minimal) !u8 {
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const arguments = try init.args.toSlice(arena.allocator());
    const options = parse(arena.allocator(), arguments) catch {
        fail("usage: wattle-pty [-w marker] [-i input] [-c cols] [-r rows] [-q quiet-ms] [-t timeout-ms] [-s [-k]] [-x] -- command [args]");
        return 2;
    };
    const steps = decode(arena.allocator(), options.input) catch {
        fail("wattle-pty: malformed input");
        return 2;
    };

    var size: std.c.winsize = .{ .row = options.rows, .col = options.columns, .xpixel = 0, .ypixel = 0 };
    const master = posix_openpt(openFlags(true));
    if (master < 0 or grantpt(master) != 0 or unlockpt(master) != 0) {
        fail("wattle-pty: cannot open a pseudo-terminal");
        return 1;
    }
    const name = ptsname(master) orelse {
        fail("wattle-pty: cannot name the pseudo-terminal");
        return 1;
    };
    const argv = try arena.allocator().allocSentinel(?[*:0]const u8, options.command.len, null);
    for (options.command, 0..) |argument, i| argv[i] = argument;

    const child = std.c.fork();
    if (child < 0) {
        fail("wattle-pty: fork failed");
        return 1;
    }
    if (child == 0) {
        _ = std.c.setsid();
        const slave = std.c.open(name, @bitCast(openFlags(false)));
        if (slave < 0) std.c._exit(126);
        _ = std.c.ioctl(slave, tiocsctty, @as(c_int, 0));
        _ = std.c.ioctl(slave, tiocswinsz, &size);
        _ = std.c.dup2(slave, 0);
        _ = std.c.dup2(slave, 1);
        _ = std.c.dup2(slave, 2);
        if (slave > 2) _ = std.c.close(slave);
        _ = std.c.close(master);
        _ = std.c.execve(argv[0].?, argv.ptr, @ptrCast(std.c.environ));
        std.c._exit(127);
    }

    var capture: Capture = .{};
    var start: usize = 0;
    if (options.marker) |marker| {
        if (!try pump(master, &capture, marker, options)) {
            fail("wattle-pty: the marker never appeared");
            stop(child, master, options.limit);
            return 1;
        }
        start = capture.bytes.items.len;
        capture.searched = start;
    }

    var pending: std.ArrayList(u8) = .empty;
    for (steps) |step| {
        switch (step) {
            .send => |bytes| try pending.appendSlice(allocator, bytes),
            .wait => |text| {
                send(master, pending.items);
                pending.clearRetainingCapacity();
                if (!try pump(master, &capture, text, options)) {
                    fail("wattle-pty: a waited-for marker never appeared");
                    stop(child, master, options.limit);
                    try emit(&capture, start, options, null);
                    return 1;
                }
            },
            .columns, .rows => {
                send(master, pending.items);
                pending.clearRetainingCapacity();
                _ = try pump(master, &capture, null, options);
                if (step == .columns) size.col = step.columns else size.row = step.rows;
                _ = std.c.ioctl(master, tiocswinsz, &size);
            },
        }
    }
    send(master, pending.items);
    _ = try pump(master, &capture, null, options);
    var report: ?[]const u8 = null;
    if (options.exit) report = try exitReport(arena.allocator(), child, master, options.limit);
    stop(child, master, options.limit);
    try emit(&capture, start, options, report);
    return 0;
}

// ==========================================================================
// Private functions
// ==========================================================================

/// Decodes the `-i` input into steps.
fn decode(arena: std.mem.Allocator, text: []const u8) ![]Step {
    var steps: std.ArrayList(Step) = .empty;
    var bytes: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] != '\\' or i + 1 >= text.len) {
            try bytes.append(arena, text[i]);
            i += 1;
            continue;
        }
        const kind = text[i + 1];
        if ((kind == 'm' or kind == 'w' or kind == 'h') and i + 2 < text.len and text[i + 2] == '{') {
            const close = std.mem.indexOfScalarPos(u8, text, i + 3, '}') orelse return error.Malformed;
            const argument = text[i + 3 .. close];
            if (bytes.items.len > 0) {
                try steps.append(arena, .{ .send = try bytes.toOwnedSlice(arena) });
            }
            try steps.append(arena, switch (kind) {
                'm' => .{ .wait = argument },
                'w' => .{ .columns = try std.fmt.parseInt(u16, argument, 10) },
                else => .{ .rows = try std.fmt.parseInt(u16, argument, 10) },
            });
            i = close + 1;
            continue;
        }
        i += 2;
        switch (kind) {
            'n' => try bytes.append(arena, '\n'),
            'r' => try bytes.append(arena, '\r'),
            't' => try bytes.append(arena, '\t'),
            'e' => try bytes.append(arena, 0x1b),
            'x' => {
                if (i + 2 > text.len) return error.Malformed;
                try bytes.append(arena, try std.fmt.parseInt(u8, text[i .. i + 2], 16));
                i += 2;
            },
            else => try bytes.append(arena, kind),
        }
    }
    if (bytes.items.len > 0) try steps.append(arena, .{ .send = try bytes.toOwnedSlice(arena) });
    return steps.toOwnedSlice(arena);
}

/// Prints the capture, or the screen it draws, to standard output.
fn emit(capture: *Capture, start: usize, options: Options, report: ?[]const u8) !void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    if (options.screen) {
        var screen = try Screen.init(options.columns, options.rows);
        for (capture.bytes.items) |byte| screen.apply(byte);
        try screen.print(&out);
        if (options.cursor) {
            var line: [48]u8 = undefined;
            try out.appendSlice(allocator, try std.fmt.bufPrint(&line, "@{d},{d}\n", .{ screen.row, screen.column }));
        }
    } else {
        try out.appendSlice(allocator, capture.bytes.items[start..]);
    }
    if (report) |lines| try out.appendSlice(allocator, lines);
    var rest = out.items;
    while (rest.len > 0) {
        const count = std.c.write(1, rest.ptr, rest.len);
        if (count <= 0) return;
        rest = rest[@intCast(count)..];
    }
}

/// Waits up to `limit` milliseconds for `child` to exit, and returns the two
/// lines `-x` prints.
///
/// The pty is still open, so the command's exit is its own and not the
/// hang-up that closing the master causes.
fn exitReport(arena: std.mem.Allocator, child: std.c.pid_t, master: c_int, limit: i64) ![]const u8 {
    var status: c_int = 0;
    var exited = false;
    const started = now();
    while (now() - started < limit) {
        if (std.c.waitpid(child, &status, std.c.W.NOHANG) == child) {
            exited = true;
            break;
        }
        const pause: std.c.timespec = .{ .sec = 0, .nsec = 10_000_000 };
        _ = std.c.nanosleep(&pause, null);
    }
    var out: std.ArrayList(u8) = .empty;
    const word: u32 = @bitCast(status);
    if (!exited) {
        try out.appendSlice(arena, "@running\n");
    } else if (word & 0x7f == 0) {
        try out.print(arena, "@exit {d}\n", .{(word >> 8) & 0xff});
    } else {
        try out.print(arena, "@signal {d}\n", .{word & 0x7f});
    }
    try out.appendSlice(arena, "@modes");
    var modes: std.c.termios = undefined;
    if (std.c.tcgetattr(master, &modes) == 0) {
        if (modes.lflag.ECHO) try out.appendSlice(arena, " echo");
        if (modes.lflag.ICANON) try out.appendSlice(arena, " icanon");
    } else {
        try out.appendSlice(arena, " unknown");
    }
    try out.append(arena, '\n');
    return out.items;
}

/// Writes `message` and a newline to standard error.
fn fail(message: []const u8) void {
    _ = std.c.write(2, message.ptr, message.len);
    _ = std.c.write(2, "\n", 1);
}

/// The C library's pseudo-terminal calls: grant access to the slave, open a
/// master, name its slave, and unlock the slave.
extern fn grantpt(fd: c_int) callconv(.c) c_int;

/// Returns the milliseconds on a monotonic clock.
fn now() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

/// Returns the flags for opening the master, or the slave when `master` is
/// false.
fn openFlags(master: bool) c_int {
    const flags: std.c.O = .{ .ACCMODE = .RDWR, .NOCTTY = master };
    return @bitCast(@as(u32, @bitCast(flags)));
}

/// Parses the command line.
fn parse(arena: std.mem.Allocator, arguments: []const [:0]const u8) !Options {
    var options: Options = .{};
    var i: usize = 1;
    while (i < arguments.len) : (i += 1) {
        const argument = arguments[i];
        if (std.mem.eql(u8, argument, "--")) {
            const command = try arena.alloc([*:0]const u8, arguments.len - i - 1);
            for (arguments[i + 1 ..], 0..) |part, j| command[j] = part.ptr;
            if (command.len == 0) return error.Usage;
            options.command = command;
            return options;
        }
        if (std.mem.eql(u8, argument, "-s")) {
            options.screen = true;
            continue;
        }
        if (std.mem.eql(u8, argument, "-k")) {
            options.cursor = true;
            continue;
        }
        if (std.mem.eql(u8, argument, "-x")) {
            options.exit = true;
            continue;
        }
        if (i + 1 >= arguments.len) return error.Usage;
        const next = arguments[i + 1];
        i += 1;
        if (std.mem.eql(u8, argument, "-w")) {
            options.marker = next;
        } else if (std.mem.eql(u8, argument, "-i")) {
            options.input = next;
        } else if (std.mem.eql(u8, argument, "-c")) {
            options.columns = try std.fmt.parseInt(u16, next, 10);
        } else if (std.mem.eql(u8, argument, "-r")) {
            options.rows = try std.fmt.parseInt(u16, next, 10);
        } else if (std.mem.eql(u8, argument, "-q")) {
            options.quiet = try std.fmt.parseInt(i64, next, 10);
        } else if (std.mem.eql(u8, argument, "-t")) {
            options.limit = try std.fmt.parseInt(i64, next, 10);
        } else {
            return error.Usage;
        }
    }
    return error.Usage;
}

extern fn posix_openpt(flags: c_int) callconv(.c) c_int;

extern fn ptsname(fd: c_int) callconv(.c) ?[*:0]const u8;

/// Reads from `master` into `capture` until `text` appears after
/// `capture.searched`, or, with no `text`, until the command has been quiet
/// for the quiet period. Returns whether `text` appeared, and true with no
/// `text`.
///
/// A found `text` moves `capture.searched` past it. Reading also ends at
/// the limit and when the command has exited.
fn pump(master: c_int, capture: *Capture, text: ?[]const u8, options: Options) !bool {
    const started = now();
    var last = now();
    while (true) {
        if (text) |t| {
            if (std.mem.indexOfPos(u8, capture.bytes.items, capture.searched, t)) |at| {
                capture.searched = at + t.len;
                return true;
            }
        } else if (now() - last > options.quiet) {
            return true;
        }
        if (now() - started > options.limit) return text == null;
        var fds = [1]std.c.pollfd{.{ .fd = master, .events = std.c.POLL.IN, .revents = 0 }};
        const ready = std.c.poll(&fds, 1, 20);
        if (ready < 0) {
            if (std.c.errno(ready) == .INTR) continue;
            return text == null;
        }
        if (ready == 0) continue;
        var chunk: [4096]u8 = undefined;
        const count = std.c.read(master, &chunk, chunk.len);
        if (count <= 0) {
            if (text) |t| {
                if (std.mem.indexOfPos(u8, capture.bytes.items, capture.searched, t)) |at| {
                    capture.searched = at + t.len;
                    return true;
                }
                return false;
            }
            return true;
        }
        try capture.bytes.appendSlice(allocator, chunk[0..@intCast(count)]);
        last = now();
    }
}

/// Writes all of `bytes` to `master`.
fn send(master: c_int, bytes: []const u8) void {
    var rest = bytes;
    while (rest.len > 0) {
        const count = std.c.write(master, rest.ptr, rest.len);
        if (count <= 0) return;
        rest = rest[@intCast(count)..];
    }
}

extern fn unlockpt(fd: c_int) callconv(.c) c_int;

/// Closes `master`, which is end of input to the command, and waits up to
/// `limit` milliseconds for the command to exit before killing it.
fn stop(child: std.c.pid_t, master: c_int, limit: i64) void {
    _ = std.c.close(master);
    const started = now();
    while (now() - started < limit) {
        var status: c_int = 0;
        if (std.c.waitpid(child, &status, std.c.W.NOHANG) != 0) return;
        const pause: std.c.timespec = .{ .sec = 0, .nsec = 10_000_000 };
        _ = std.c.nanosleep(&pause, null);
    }
    _ = std.c.kill(child, .KILL);
    _ = std.c.waitpid(child, null, 0);
}
