const arch = @import("../arch.zig");

const std = @import("std");

const Color = @import("colors.zig").Basic;

// STATE / INITIALIZATION

const width = 80;
const height = 25;
const size = width * height;

buf: []Entry,
pos: u16 = 0,

foreground: Color = .light_gray,
background: Color = .black,

cursor: bool = true,

const Self = @This();

pub inline fn initAddr(addr: usize) Self {
    return .{ .buf = @as([*]Entry, @ptrFromInt(addr))[0..size] };
}

pub inline fn init(ptr: anytype) Self {
    if (@typeInfo(@TypeOf(ptr)) != .pointer)
        @compileError("non-pointer in Console.TextMode.init");

    return .{ .buf = @as([*]Entry, @ptrCast(ptr))[0..size] };
}

// IMPLEMENTATION

const Entry = packed struct {
    char: u8,
    foreground: Color,
    background: Color,

    pub inline fn fromChar(state: *const Self, char: u8) Entry {
        return .{
            .char = char,
            .foreground = state.foreground,
            .background = state.background,
        };
    }
};

pub inline fn writeChar(self: *Self, char: u8) void {
    self.buf[self.pos] = Entry.fromChar(self, char);
    self.pos += 1;
}

fn put(self: *Self, char: u8) void {
    switch (char) {
        '\n' => {
            self.pos += width - (self.pos % width);
            if (self.pos >= size) self.scroll();
        },
        // BS / DEL
        '\x08', '\x7F' => if (self.pos > 0) {
            self.pos -= 1;
            self.buf[self.pos] = Entry.fromChar(self, ' ');
        },
        else => {
            self.buf[self.pos] = Entry.fromChar(self, char);
            self.pos += 1;
            if (self.pos >= size) self.scroll();
        },
    }
}

inline fn scroll(self: *Self) void {
    // Copy buffer data starting from the second line to the start.
    std.mem.copyForwards(Entry, self.buf[0 .. size - width], self.buf[width..]);
    // Clear the last line.
    @memset(self.buf[size - width ..], Entry.fromChar(self, ' '));
    // Move cursor position up a row.
    self.pos -= width;
    // Update cursor.
    self.updateCursor();
}

pub inline fn print(self: *Self, string: []const u8) void {
    for (string) |char| self.put(char);
    self.updateCursor();
}

pub inline fn clear(self: *Self) void {
    @memset(self.buf, Entry.fromChar(self, ' '));
    self.pos = 0;
}

inline fn updateCursor(self: *const Self) void {
    @import("../arch.zig").updateTextModeCursor(self);
}
