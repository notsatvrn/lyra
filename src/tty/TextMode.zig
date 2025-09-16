const std = @import("std");

const tty = @import("../tty.zig");
const io = @import("../io.zig");
const Color = @import("colors.zig").Basic;
const state = &tty.state;

// STATE / INITIALIZATION

const width = 80;
const height = 25;
const size = width * height;

const buffer = @as([*]Entry, @ptrFromInt(0xB8000))[0..size];

pos: u16 = 0,
cursor: bool = true,

const Self = @This();

// IMPLEMENTATION

const Entry = packed struct {
    char: u8,
    foreground: Color,
    background: Color,

    pub inline fn fromChar(char: u8) Entry {
        return .{
            .char = char,
            .foreground = state.getPart(.foreground).basic,
            .background = state.getPart(.background).basic,
        };
    }
};

inline fn put(self: *Self, char: u8) void {
    switch (char) {
        '\n' => {
            self.pos += width - (self.pos % width);
            if (self.pos >= size) self.scroll();
        },
        // BS / DEL
        '\x08', '\x7F' => if (self.pos > 0) {
            self.pos -= 1;
            buffer[self.pos] = Entry.fromChar(' ');
        },
        else => {
            buffer[self.pos] = Entry.fromChar(char);
            self.pos += 1;
            if (self.pos >= size) self.scroll();
        },
    }
}

inline fn updateCursor(self: Self) void {
    if (!self.cursor) return;

    io.out(u8, 0x3D4, 0x0F);
    io.out(u8, 0x3D5, @truncate(self.pos));
    io.out(u8, 0x3D4, 0x0E);
    io.out(u8, 0x3D5, @truncate(self.pos >> 8));
}

pub fn toggleCursor(self: *Self) void {
    self.cursor = !self.cursor;
    if (self.cursor) self.updateCursor();
}

inline fn scroll(self: *Self) void {
    // Copy buffer data starting from the second line to the start.
    std.mem.copyForwards(Entry, buffer[0 .. size - width], buffer[width..]);
    // Clear the last line.
    @memset(buffer[size - width ..], Entry.fromChar(' '));
    // Move cursor position up a row.
    self.pos -= width;
    // Update cursor.
    self.updateCursor();
}

pub fn print(self: *Self, string: []const u8) void {
    for (string) |char| self.put(char);
    self.updateCursor();
}

pub inline fn clear(self: *Self) void {
    @memset(buffer, Entry.fromChar(' '));
    self.pos = 0;
    self.updateCursor();
}
