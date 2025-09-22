const std = @import("std");
const Level = std.log.Level;

pub const tty = @import("tty.zig");
pub const colors = tty.colors;
pub const Ansi = tty.effects.Command;

const memory = @import("memory.zig");
const smp = @import("smp.zig");

const Lock = @import("utils").lock.SpinLock;
const nanoSinceBoot = @import("clock.zig").nanoSinceBoot;
const halt = @import("util.zig").halt;

// LOG BUFFER

var lock = Lock{};
pub var buffer = std.ArrayList(u8){};
const buf_writer = buffer.writer(memory.allocator);

// LOGGER STRUCTURE

// Configurable minimum log levels.
pub var buffer_level = Level.debug;
pub var tty_level = Level.info;

pub fn levelColor(level: Level) colors.Basic {
    return switch (level) {
        .debug => .light_cyan,
        .info => .light_green,
        .warn => .yellow,
        .err => .light_red,
    };
}
pub fn levelName(level: Level) []const u8 {
    return switch (level) {
        .debug => "DEBUG",
        .info => "INFO ",
        .warn => "WARN ",
        .err => "ERROR",
    };
}

pub const Logger = struct {
    name: []const u8,

    pub fn log(self: Logger, level: Level, comptime fmt: []const u8, args: anytype) void {
        const time = nanoSinceBoot() / std.time.ns_per_us;
        const micros = time % std.time.us_per_s;
        const secs = time / std.time.us_per_s;

        if (@intFromEnum(level) <= @intFromEnum(tty_level)) {
            tty.lock.lock();
            defer tty.lock.unlock();
            var writer = tty.writer.adaptToNewApi(&.{});
            self.logToWriter(&writer.new_interface, micros, secs, level, fmt, args) catch unreachable;
        }
        if (memory.ready and @intFromEnum(level) <= @intFromEnum(buffer_level)) {
            lock.lock();
            defer lock.unlock();
            var writer = buf_writer.adaptToNewApi(&.{});
            self.logToWriter(&writer.new_interface, micros, secs, level, fmt, args) catch {
                // clear the log buffer
                buffer.clearAndFree(memory.allocator);
                // at this point it should be able to write
                self.logToWriter(&writer.new_interface, micros, secs, level, fmt, args) catch
                    @panic("unable to write to log buffer");
            };
        }
    }

    fn logToWriter(self: Logger, writer: *std.Io.Writer, micros: usize, secs: usize, level: Level, comptime fmt: []const u8, args: anytype) !void {
        try writer.print("{f}[{d: >5}.{d:0>6}] ", .{ Ansi.reset, secs, micros });
        const color = Ansi.setColor(.foreground, .{ .basic = levelColor(level) });
        try writer.print("[{f}{s}{f}] ", .{ color, levelName(level), Ansi.reset });
        if (smp.launched) {
            @branchHint(.likely); // post-boot we're in smp
            try writer.print("[CPU {}] ", .{smp.getCpu()});
        }
        try writer.print("{s}) ", .{self.name});
        try writer.print(fmt, args);
        try writer.writeByte('\n');
    }

    pub inline fn panic(self: Logger, comptime fmt: []const u8, args: anytype) noreturn {
        std.debug.panic("{s}) " ++ fmt, .{self.name} ++ args);
    }

    pub inline fn info(self: Logger, comptime fmt: []const u8, args: anytype) void {
        self.log(.info, fmt, args);
    }

    pub inline fn debug(self: Logger, comptime fmt: []const u8, args: anytype) void {
        self.log(.debug, fmt, args);
    }

    pub inline fn warn(self: Logger, comptime fmt: []const u8, args: anytype) void {
        self.log(.warn, fmt, args);
    }

    pub inline fn err(self: Logger, comptime fmt: []const u8, args: anytype) void {
        self.log(.err, fmt, args);
    }
};

// PANIC

pub fn panic(msg: []const u8, first_trace_addr: ?usize) noreturn {
    @branchHint(.cold);
    tty.lock.lock();
    tty.state.setColor(.foreground, .{ .basic = .light_red });
    tty.state.setColor(.underline, .{ .basic = .light_red });
    tty.state.effects.set(.underline, .single);
    tty.writer.print("[PANIC] {s}", .{msg}) catch unreachable;
    tty.writer.print("call trace:", .{}) catch unreachable;

    var it = std.debug.StackIterator.init(first_trace_addr, null);
    while (it.next()) |return_address| {
        const address = return_address -| 5;
        if (address == 0) break;
        tty.writer.print("- 0x{X:0>16}", .{address}) catch unreachable;
    }

    tty.sync();
    halt();
}
