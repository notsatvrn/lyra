const std = @import("std");
const Level = std.log.Level;

pub const tty = @import("tty.zig");
pub const colors = tty.colors;
pub const Ansi = tty.effects.Ansi;

const Lock = @import("utils").lock.SpinLock;
const nanoSinceBoot = @import("clock.zig").nanoSinceBoot;
const halt = @import("util.zig").halt;

var lock = Lock{};

// LOG BUFFER

const memory = @import("memory.zig");

pub var buffer = std.ArrayList(u8){};
const buf_writer = buffer.writer(memory.allocator);

// BASIC PRINTING / WRITER

fn write(_: *const anyopaque, bytes: []const u8) error{}!usize {
    tty.print(bytes);
    if (memory.ready)
        buf_writer.writeAll(bytes) catch
            @panic("OOM in log");
    return bytes.len;
}

var writer = std.Io.AnyWriter{ .context = undefined, .writeFn = &write };

inline fn timeAndReset() void {
    const sec = @as(f64, @floatFromInt(nanoSinceBoot())) / std.time.ns_per_s;
    writer.print("{f}[{d: >12.6}] ", .{ Ansi.reset, sec }) catch unreachable;
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

        printfu("[{f}{s}{f}] {s}: ", .{ Ansi.setColor(.foreground, .{ .basic = color }), str, Ansi.reset, self.name });

        // print message

        printfu(fmt ++ "\n", args);
        tty.sync();
        lock.unlock();
    }

    pub fn panic(self: Logger, comptime fmt: []const u8, args: anytype) noreturn {
        @branchHint(.cold);
        std.debug.panic("{s}: " ++ fmt, .{self.name} ++ args);
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
    tty.sync();
    halt();
}
