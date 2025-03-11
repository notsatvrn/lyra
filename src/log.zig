const std = @import("std");
const Level = std.log.Level;

pub const tty = @import("tty.zig");
pub const colors = tty.colors;
pub const ANSI = tty.effects.ANSI;

const arch = @import("arch.zig");
const nanoSinceBoot = arch.time.nanoSinceBoot;
const Lock = @import("util/lock.zig").Lock;

var lock = Lock{};

// BASIC PRINTING / WRITER

fn write(_: void, bytes: []const u8) error{}!usize {
    nosuspend tty.out.print(bytes);
    return bytes.len;
}

const Writer = std.io.Writer(void, error{}, write);
var writer: Writer = .{ .context = void{} };

inline fn timeAndReset() void {
    const sec = @as(f64, @floatFromInt(nanoSinceBoot())) / std.time.ns_per_s;
    writer.print("{s}[{d: >12.6}] ", .{ ANSI.reset, sec }) catch unreachable;
}

// printf unprefixed
inline fn printfu(comptime fmt: []const u8, args: anytype) void {
    writer.print(fmt, args) catch unreachable;
}

pub inline fn printf(comptime fmt: []const u8, args: anytype) void {
    lock.lock();
    timeAndReset();
    printfu(fmt, args);
    lock.unlock();
}

// BASIC LOGGING

pub const Logger = struct {
    name: []const u8,

    inline fn log(self: Logger, comptime level: Level, comptime fmt: []const u8, args: anytype) void {
        lock.lock();
        timeAndReset();

        // print [<level>] with color

        var color: colors.Basic = .green;
        var str: []const u8 = "INFO ";

        switch (level) {
            .debug => {
                color = .cyan;
                str = "DEBUG";
            },
            .warn => {
                color = .yellow;
                str = "WARN ";
            },
            .err => {
                color = .red;
                str = "ERROR";
            },
            else => {},
        }

        printfu("[{s}{s}{s}] {s}: ", .{ ANSI.setColor(.foreground, .{ .basic = color }), str, ANSI.reset, self.name });

        // print message

        printfu(fmt ++ "\n", args);
        tty.sync();
        lock.unlock();
    }

    pub fn info(self: Logger, comptime fmt: []const u8, args: anytype) void {
        self.log(.info, fmt, args);
    }

    pub fn debug(self: Logger, comptime fmt: []const u8, args: anytype) void {
        self.log(.debug, fmt, args);
    }

    pub fn warn(self: Logger, comptime fmt: []const u8, args: anytype) void {
        self.log(.warn, fmt, args);
    }

    pub fn err(self: Logger, comptime fmt: []const u8, args: anytype) void {
        self.log(.err, fmt, args);
    }
};

// PANIC

pub inline fn panic(first_trace_addr: ?usize, comptime fmt: []const u8, args: anytype) noreturn {
    @branchHint(.cold);
    _ = first_trace_addr;
    lock.lock();
    timeAndReset();
    writer.print("[PANIC] " ++ fmt ++ "\n", args) catch unreachable;
    //if (ert) |s| writer.print("stack trace:\n{}", .{s}) catch unreachable;
    tty.sync();
    arch.halt();
}
