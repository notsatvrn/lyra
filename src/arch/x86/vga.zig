const std = @import("std");
const io = @import("io.zig");

const width = 80;
const height = 25;
const size = width * height;

const State = struct {
    buf: []Entry = @as([*]Entry, @ptrFromInt(0xB8000))[0..size],
    pos: u16 = 0,

    foreground: Color = .light_gray,
    background: Color = .black,

    cursor: bool = true,
};

var state = State{};

pub const Color = enum(u4) {
    black,
    blue,
    green,
    cyan,
    red,
    magenta,
    brown,
    light_gray,
    dark_gray,
    light_blue,
    light_green,
    light_cyan,
    light_red,
    light_magenta,
    light_brown,
    white,
};

pub const Entry = packed struct {
    char: u8,
    foreground: Color,
    background: Color,

    pub inline fn fromChar(char: u8) Entry {
        return .{
            .char = char,
            .foreground = state.foreground,
            .background = state.background,
        };
    }
};

pub inline fn put(char: u8) void {
    switch (char) {
        '\n' => {
            state.pos += width - (state.pos % width);
            if (state.pos >= size) scroll();
        },
        // BS / DEL
        '\x08', '\x7F' => if (state.pos > 0) {
            state.pos -= 1;
            state.buf[state.pos] = Entry.fromChar(' ');
        },
        else => {
            state.buf[state.pos] = Entry.fromChar(char);
            state.pos += 1;
            if (state.pos >= size) scroll();
        },
    }
}

// Scroll down a line.
pub inline fn scroll() void {
    // Copy buffer data starting from the second line to the start.
    std.mem.copyForwards(Entry, state.buf[0 .. size - width], state.buf[width..]);
    // Clear the last line.
    @memset(state.buf[size - width ..], Entry.fromChar(' '));
    // Move cursor position up a row.
    state.pos -= width;
    // Update cursor.
    updateCursor();
}

pub inline fn print(string: []const u8) void {
    for (string) |char| put(char);
    updateCursor();
}

pub inline fn clear() void {
    @memset(state.buf, Entry.fromChar(' '));
    state.pos = 0;
}

// CURSOR HANDLING

pub inline fn updateCursor() void {
    if (!state.cursor) return;

    io.out(0x3D4, @as(u8, 0x0F));
    io.out(0x3D5, @as(u8, @truncate(state.pos)));
    io.out(0x3D4, @as(u8, 0x0E));
    io.out(0x3D5, @as(u8, @truncate(state.pos >> 8)));
}

// FORMATTING

inline fn writeAll(bytes: []const u8) Writer.Error!void {
    print(bytes);
}

inline fn writeBytesNTimes(bytes: []const u8, n: usize) Writer.Error!void {
    var i: usize = 0;
    while (i < n) : (i += 1) print(bytes);
}

const Writer = struct {
    pub const Error = error{};
    writeAll: fn ([]const u8) callconv(.Inline) Error!void = writeAll,
    writeBytesNTimes: fn ([]const u8, usize) callconv(.Inline) Error!void = writeBytesNTimes,
};

const writer = Writer{};

pub inline fn printf(comptime fmt: []const u8, args: anytype) void {
    std.fmt.format(writer, fmt, args) catch unreachable;
}
