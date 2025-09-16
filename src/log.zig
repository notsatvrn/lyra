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

const WriteError = std.mem.Allocator.Error;

fn write(_: void, bytes: []const u8) WriteError!usize {
    tty.print(bytes);
    if (memory.ready) try buf_writer.writeAll(bytes);
    return bytes.len;
}

const writer = std.Io.GenericWriter(void, WriteError, write){ .context = void{} };

fn printRaw(comptime fmt: []const u8, args: anytype) !void {
    const sec = @as(f64, @floatFromInt(nanoSinceBoot())) / std.time.ns_per_s;
    try writer.print("{f}[{d: >12.6}] " ++ fmt ++ "\n", .{ Ansi.reset, sec } ++ args);
}

pub fn print(comptime fmt: []const u8, args: anytype) void {
    lock.lock();
    defer lock.unlock();
    printRaw(fmt, args) catch {
        // clear the log buffer
        buffer.clearAndFree(memory.allocator);
        // at this point it should be able to write
        printRaw(fmt, args) catch
            @panic("unable to write to log buffer");
    };
    tty.sync();
}

// BASIC LOGGING

pub const Logger = struct {
    name: []const u8,

    inline fn log(self: Logger, comptime level: Level, comptime fmt: []const u8, args: anytype) void {
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

        const ansi_color = Ansi.setColor(.foreground, .{ .basic = color });
        print("[{f}{s}{f}] {s}: " ++ fmt, .{ ansi_color, str, Ansi.reset, self.name } ++ args);
    }

    pub inline fn panic(self: Logger, comptime fmt: []const u8, args: anytype) noreturn {
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

pub fn panic(first_trace_addr: ?usize, comptime fmt: []const u8, args: anytype) noreturn {
    @branchHint(.cold);
    lock.lock();
    memory.ready = false; // stop allocating log buffer
    printRaw("[PANIC] " ++ fmt, args) catch unreachable;
    printRaw("call trace:", .{}) catch unreachable;

    var it = std.debug.StackIterator.init(first_trace_addr, null);
    while (it.next()) |return_address| {
        const address = return_address -| 1;
        if (address == 0) break;
        printRaw("- 0x{x:0>16}", .{address}) catch unreachable;
    }

    tty.sync();
    halt();
}
