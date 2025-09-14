//! A framebuffer-based text-mode tty emulator.
//! Supports a wide range of text effects.

const std = @import("std");

const gfx = @import("../gfx.zig");
const Framebuffer = gfx.Framebuffer;
const Rect = gfx.Rect;

const tty = @import("../tty.zig");
const RenderState = tty.RenderState;
const ColorPart = tty.effects.ColorPart;
const Ansi = tty.effects.Ansi;
const Rgb = tty.colors.Rgb;

const limine = @import("../limine.zig");
const VideoMode = limine.Framebuffer.VideoMode;

const memory = @import("../memory.zig");

info: Info,
font: *const [256][16]u8 = &@import("fonts.zig").oldschoolPGC.data,
buffer: Framebuffer,
cursor: Cursor = .{},
// double-buffering and multi-monitor
virtual: ?*Virtual = null,

const Info = struct {
    // emulated text area res
    cols: usize,
    rows: usize,
    // text area padding
    // should always be black
    hpad: u8,
    vpad: u8,

    pub inline fn init(mode: *const VideoMode) Info {
        return .{
            .cols = mode.width / 8,
            .rows = mode.height / 16,
            .hpad = @truncate(mode.width % 8),
            .vpad = @truncate(mode.height % 16),
        };
    }
};

const Cursor = struct {
    row: usize = 0,
    col: usize = 0,
    show: bool = true,
};

const Virtual = struct {
    outputs: std.ArrayList(Framebuffer) = .{},
    damage: Rect = .{},
};

const Self = @This();

pub inline fn initVirtual(mode: *const VideoMode) !Self {
    const buf = try memory.allocator.alloc(u8, mode.pitch * mode.height);
    var self = Self.init(buf.ptr, mode);
    self.virtual = try memory.allocator.create(Virtual);
    self.virtual.?.* = .{};
    return self;
}

pub inline fn init(ptr: [*]u8, mode: *const VideoMode) Self {
    return .{
        .info = Info.init(mode),
        .buffer = Framebuffer.init(ptr, mode),
    };
}

// PLACING CHARACTERS

pub fn getPixel(self: Self, comptime part: ColorPart) u64 {
    const color = tty.state.getColor(.{ .rgb = .bpp36 }, part);
    return self.buffer.makePixel(color);
}

inline fn writeCharRow(self: *Self, pos: usize, data: u8, fg: u64, bg: u64, comptime replace: bool) void {
    var offset: usize = pos;
    switch (self.buffer.bytes) {
        inline 2...5 => |bytes| for (0..8) |i| {
            const bit: u3 = @truncate(7 - i);
            const set = (data >> bit & 1) == 1;
            if (replace) {
                self.buffer.writePixelBytes(bytes, offset, if (set) fg else bg);
            } else if (set) self.buffer.writePixelBytes(bytes, offset, fg);
            offset += bytes;
        },
        else => unreachable,
    }
}

inline fn writeChar(self: *Self, c: u8) void {
    const pitch = self.buffer.mode.pitch;

    const x = self.cursor.col * 8;
    const y = self.cursor.row * 16;

    var offset = (x * self.buffer.bytes) + (y * pitch);
    self.cursor.col += 1;

    if (self.cursor.col - 1 > self.info.cols) return;

    if (self.virtual) |virtual| virtual.damage.add(.{
        .corner = .{ x, y },
        .dimensions = .{ 8, 16 },
    });

    const bg = self.getPixel(.background);

    // fast path for hidden
    if (tty.state.effects.get(.hidden))
        return self.buffer.drawRect(offset, bg, 8, 16);

    // get character data and apply some effects

    var data = self.font[c];

    if (tty.state.effects.get(.bold)) {
        inline for (data, 0..) |r, i|
            data[i] |= r << 1;
    }

    if (tty.state.effects.get(.overline)) data[1] = 0xFF;
    if (tty.state.effects.get(.strikethru)) data[7] = 0xFF;

    // write the character!

    const fg = self.getPixel(.foreground);

    inline for (data) |row| {
        self.writeCharRow(offset, row, fg, bg, true);
        offset += pitch;
    }

    // we support custom underline color using \e[58...m

    const underline = tty.state.effects.get(.underline) orelse return;

    offset -= pitch * 2;
    const color = self.getPixel(.underline);

    switch (underline) {
        .single => self.buffer.writePixelNTimes(offset, color, 8),
        .double => {
            offset -= pitch;
            self.buffer.writePixelNTimes(offset, color, 8);
            offset += pitch * 2;
            self.buffer.writePixelNTimes(offset, color, 8);
        },
        .curly => {
            self.writeCharRow(offset, 0b10011001, color, undefined, false);
            offset += pitch;
            self.writeCharRow(offset, 0b01100110, color, undefined, false);
        },
        .dotted => self.writeCharRow(offset, 0b10101010, color, undefined, false),
        .dashed => self.writeCharRow(offset, 0b11101110, color, undefined, false),
    }
}

// SPECIAL CHARACTER HANDLING

fn put(self: *Self, char: u8) void {
    if (tty.state.checkChar(char)) return;
    switch (char) {
        '\n' => {
            self.cursor.row += 1;
            self.cursor.col = 0;
            if (self.cursor.row >= self.info.rows)
                self.scroll();
        },
        // BS / DEL
        '\x08', '\x7F' => {
            if (self.cursor.col > 0) {
                self.cursor.col -= 1;
            } else if (self.cursor.row > 0) {
                self.cursor.row -= 1;
                self.cursor.col = self.info.cols - 1;
            } else return;
            self.put(' ');
        },
        else => self.writeChar(char),
    }
}

pub inline fn print(self: *Self, string: []const u8) void {
    for (string) |c| self.put(c);
}

// SCROLLING / CLEARING

inline fn scroll(self: *Self) void {
    const line_size = self.buffer.mode.pitch * 16;
    const bottom_end = line_size * self.info.rows;
    const top_end = bottom_end - line_size;
    // Copy buffer data starting from the second line to the start.
    std.mem.copyForwards(u8, self.buffer.buf[0..top_end], self.buffer.buf[line_size..bottom_end]);
    // Clear the last line.
    @memset(self.buffer.buf[top_end..], 0);
    // Move the cursor up a line.
    self.cursor.row -= 1;
    // Damage the whole screen.
    self.damageFull();
}

pub inline fn clear(self: *Self) void {
    self.buffer.clear();
    self.cursor.row = 0;
    self.cursor.col = 0;
    self.damageFull();
}

// MIRRORING

inline fn damageFull(self: *Self) void {
    if (self.virtual) |virtual| virtual.damage = .{
        .corner = .{ 0, 0 },
        .dimensions = .{
            self.info.cols * 16,
            self.info.rows * 8,
        },
    };
}

pub inline fn sync(self: *Self) void {
    const virtual = self.virtual orelse return;
    if (virtual.damage.isClear()) return;
    for (virtual.outputs.items) |*dst|
        dst.copy(&self.buffer, virtual.damage);
    virtual.damage = .{};
}

pub inline fn addOutput(self: *Self, buffer: Framebuffer) !void {
    if (self.virtual == null) return error.NotVirtual;
    try self.virtual.?.outputs.append(memory.allocator, buffer);
}
