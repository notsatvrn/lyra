const std = @import("std");
const Level = std.log.Level;

pub const tty = @import("tty.zig");
pub const colors = tty.colors;
pub const Ansi = tty.effects.Command;

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
    const time = nanoSinceBoot() / std.time.ns_per_us;
    const micros = time % std.time.us_per_s;
    const secs = time / std.time.us_per_s;
    try writer.print("{f}[{d: >5}.{d:0>6}] " ++ fmt ++ "\n", .{ Ansi.reset, secs, micros } ++ args);
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

const smp = @import("smp.zig");

/// Configurable minimum log level.
pub var min_level = Level.info;

pub const Logger = struct {
    name: []const u8,

    inline fn log(self: Logger, comptime level: Level, comptime fmt: []const u8, args: anytype) void {
        if (@intFromEnum(level) > @intFromEnum(min_level)) return;

        var color: colors.Basic = .light_green;
        var str: []const u8 = "INFO ";

        switch (level) {
            .debug => {
                color = .light_cyan;
                str = "DEBUG";
            },
            .warn => {
                color = .yellow;
                str = "WARN ";
            },
            .err => {
                color = .light_red;
                str = "ERROR";
            },
            else => {},
        }

        const ansi_color = Ansi.setColor(.foreground, .{ .basic = color });
        if (!smp.launched) {
            @branchHint(.unlikely);
            print("[{f}{s}{f}] {s}) " ++ fmt, .{ ansi_color, str, Ansi.reset, self.name } ++ args);
        } else {
            print("[{f}{s}{f}] [CPU {}] {s}) " ++ fmt, .{ ansi_color, str, Ansi.reset, smp.getCpu(), self.name } ++ args);
        }
    }

    pub inline fn panic(self: Logger, comptime fmt: []const u8, args: anytype) noreturn {
        std.debug.panic("{s}) " ++ fmt, .{self.name} ++ args);
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

pub fn panic(msg: []const u8, first_trace_addr: ?usize) noreturn {
    @branchHint(.cold);
    lock.lock();
    memory.ready = false; // stop allocating log buffer
    tty.state.setColor(.foreground, .{ .basic = .light_red });
    tty.state.setColor(.underline, .{ .basic = .light_red });
    tty.state.effects.set(.underline, .single);
    printRaw("[PANIC] {s}", .{msg}) catch unreachable;
    printRaw("call trace:", .{}) catch unreachable;

    var it = std.debug.StackIterator.init(first_trace_addr, null);
    while (it.next()) |return_address| {
        const address = return_address -| 5;
        if (address == 0) break;
        printRaw("- 0x{X:0>16}", .{address}) catch unreachable;
    }

    tty.sync();
    halt();
}
