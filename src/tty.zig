const std = @import("std");

const gfx = @import("gfx.zig");
const Framebuffer = gfx.Framebuffer;
const Rect = gfx.Rect;

const oldschoolPGC = @import("tty/fonts.zig").oldschoolPGC;

pub const colors = @import("tty/colors.zig");
pub const Color = colors.Color;
const Rgb = colors.Rgb;

pub const effects = @import("tty/effects.zig");
pub const ColorPart = effects.ColorPart;
pub const Ansi = effects.Ansi;

const limine = @import("limine.zig");
const VideoMode = limine.Framebuffer.VideoMode;

const allocator = @import("memory.zig").allocator;

// STRUCTURES

var buffer: Framebuffer = undefined;

var info: Info = undefined;
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
            .cols = mode.width / font.width,
            .rows = mode.height / font.height,
            .hpad = @truncate(mode.width % font.width),
            .vpad = @truncate(mode.height % font.height),
        };
    }
};

var font: Font = .{};
const Font = struct {
    width: usize = 8,
    height: usize = 16,
    data: [*]const u8 = @ptrCast(&oldschoolPGC),
};

var cursor: Cursor = .{};
const Cursor = struct {
    row: usize = 0,
    col: usize = 0,
    show: bool = true,
};

var virtual: ?Virtual = null;
const Virtual = struct {
    outputs: std.ArrayList(Framebuffer) = .{},
    damage: Rect = .{},
};

// PLACING CHARACTERS

inline fn getPixel(comptime part: ColorPart) u64 {
    const color = state.getColor(part);
    return buffer.makePixel(color);
}

fn writeCharRow(pos: usize, data: u8, fg: u64, bg: u64, comptime replace: bool) void {
    var offset: usize = pos;
    for (0..font.width) |i| {
        const bit: u3 = @truncate(font.width - 1 - i);
        const set = (data >> bit & 1) == 1;
        if (replace) {
            buffer.writePixel(offset, if (set) fg else bg);
        } else if (set) buffer.writePixel(offset, fg);
        offset += buffer.bytes;
    }
}

inline fn writeChar(c: u21) void {
    const pitch = buffer.mode.pitch;

    const x = cursor.col * font.width;
    const y = cursor.row * font.height;

    var offset = (x * buffer.bytes) + (y * pitch);
    cursor.col += 1;

    if (cursor.col - 1 > info.cols) return;

    if (virtual) |*v| v.damage.add(.{
        .corner = .{ x, y },
        .dimensions = .{ font.width, font.height },
    });

    const bg = getPixel(.background);

    // fast path for hidden
    if (state.effects.get(.hidden))
        return buffer.drawRect(offset, bg, font.width, font.height);

    // write the character!

    const fg = getPixel(.foreground);
    const bold = state.effects.get(.bold);

    const width_bytes = (font.width + 7) / 8;
    var char_offset = (c * width_bytes * font.height);
    for (0..font.height) |_| {
        var row = font.data[char_offset];
        if (bold) row |= row << 1;
        writeCharRow(offset, row, fg, bg, true);
        offset += pitch;
        char_offset += width_bytes;
    }

    offset -= pitch * font.height;
    if (state.effects.get(.overline))
        buffer.writePixelNTimes(offset + pitch, fg, font.width);
    if (state.effects.get(.strikethru))
        buffer.writePixelNTimes(offset + (pitch * (font.height / 2) - 1), fg, font.width);
    offset += pitch * font.height;

    // we support custom underline color using \e[58...m

    const underline = state.effects.get(.underline) orelse return;

    offset -= pitch * 2;
    const color = getPixel(.underline);

    switch (underline) {
        .single => buffer.writePixelNTimes(offset, color, font.width),
        .double => {
            offset -= pitch;
            buffer.writePixelNTimes(offset, color, font.width);
            offset += pitch * 2;
            buffer.writePixelNTimes(offset, color, font.width);
        },
        .curly => {
            writeCharRow(offset, 0b10011001, color, undefined, false);
            offset += pitch;
            writeCharRow(offset, 0b01100110, color, undefined, false);
        },
        .dotted => writeCharRow(offset, 0b10101010, color, undefined, false),
        .dashed => writeCharRow(offset, 0b11101110, color, undefined, false),
    }
}

// SPECIAL CHARACTER HANDLING

pub fn put(c: u8) void {
    const char = state.parse(c) orelse return;
    // TODO: unicode lookup table
    if (char >= 128) return;
    switch (char) {
        '\n' => {
            cursor.row += 1;
            cursor.col = 0;
            if (cursor.row >= info.rows)
                scroll();
        },
        // BS / DEL
        '\x08', '\x7F' => {
            if (cursor.col > 0) {
                cursor.col -= 1;
            } else if (cursor.row > 0) {
                cursor.row -= 1;
                cursor.col = info.cols - 1;
            } else return;
            put(' ');
        },
        else => writeChar(char),
    }
}

pub inline fn print(string: []const u8) void {
    for (string) |c| put(c);
}

// SCROLLING / CLEARING

inline fn scroll() void {
    const line_size = buffer.mode.pitch * font.height;
    const bottom_end = line_size * info.rows;
    const top_end = bottom_end - line_size;
    // Copy buffer data starting from the second line to the start.
    std.mem.copyForwards(u8, buffer.buf[0..top_end], buffer.buf[line_size..bottom_end]);
    // Clear the last line.
    @memset(buffer.buf[top_end..], 0);
    // Move the cursor up a line.
    cursor.row -= 1;
    // Damage the whole screen.
    damageFull();
}

pub fn clear() void {
    buffer.clear();
    cursor.row = 0;
    cursor.col = 0;
    damageFull();
}

// MIRRORING

fn damageFull() void {
    if (virtual) |*v| v.damage = .{
        .corner = .{ 0, 0 },
        .dimensions = .{
            info.cols * font.width,
            info.rows * font.height,
        },
    };
}

pub fn sync() void {
    const v = &(virtual orelse return);
    if (v.damage.isClear()) return;
    for (v.outputs.items) |*dst|
        dst.copy(&buffer, v.damage);
    v.damage = .{};
}

pub inline fn addOutput(buf: Framebuffer) !void {
    if (virtual == null) return error.NotVirtual;
    try virtual.?.outputs.append(allocator, buf);
}

// STATE

const Basic = colors.Basic;
const Effects = effects.Effects;
const AnsiParser = effects.AnsiParser;

pub var state = State{};

// The current rendering state of the tty.
// Handles colors, effects, and ANSI escapes.
pub const State = struct {
    default: Colors = .init(&colors.palette16),
    current: Colors = .init(&colors.palette16),
    effects: Effects = .{},
    palette: [16]Rgb = colors.palette16,
    ansi: AnsiParser = .{},
    unicode: UnicodeParser = .{},

    pub const Colors = struct {
        foreground: Rgb,
        dim_foreground: Rgb,
        underline: Rgb,
        dim_underline: Rgb,
        background: Rgb,

        pub fn init(palette: *const [16]Rgb) Colors {
            const fg = palette[@intFromEnum(Basic.light_gray)];
            const bg = palette[@intFromEnum(Basic.black)];
            const dim_fg = fg.mix(bg, 0.75);
            return .{
                .foreground = fg,
                .dim_foreground = dim_fg,
                .underline = fg,
                .dim_underline = dim_fg,
                .background = bg,
            };
        }
    };

    pub const UnicodeParser = struct {
        buffer: [4]u8 = undefined,
        index: u2 = 0,
        active: bool = false,

        pub fn parse(self: *UnicodeParser, char: u8) ?u21 {
            if (!self.active or char < 128) {
                // applications will mostly be
                // outputting ASCII characters
                @branchHint(.likely);
                self.index = 0;
                return char;
            }

            self.buffer[self.index] = char;
            self.index +%= 1;

            const index: u2 = switch (self.buffer[0]) {
                0b0000_0000...0b0111_1111 => unreachable,
                0b1100_0000...0b1101_1111 => 1,
                0b1110_0000...0b1110_1111 => 2,
                0b1111_0000...0b1111_0111 => 3,
                else => return null,
            };

            if (index != self.index) {
                // applications will mostly be
                // outputting valid UTF-8
                @branchHint(.unlikely);
                self.index = 0;
                return null;
            }

            return switch (index) {
                1 => std.unicode.utf8Decode2(self.buffer[0..2].*) catch null,
                2 => std.unicode.utf8Decode3(self.buffer[0..3].*) catch null,
                3 => std.unicode.utf8Decode4(self.buffer[0..4].*) catch null,
                else => unreachable,
            };
        }
    };

    const Self = @This();

    pub fn parse(self: *Self, char: u8) ?u21 {
        if (self.ansi.checkChar(char)) return null;
        return self.unicode.parse(char);
    }

    pub fn getColor(self: Self, comptime part: ColorPart) Rgb {
        if (part == .background) return self.current.background;

        const dim = self.effects.get(.dim);
        if (dim) return @field(self.current, "dim_" ++ @tagName(part));
        return @field(self.current, @tagName(part));
    }

    inline fn convertColor(self: Self, c: Color) Rgb {
        return switch (c) {
            .rgb => |v| v,
            .basic => |v| self.palette[@intFromEnum(v)],
            .@"256" => |v| if (v < 16)
                self.palette[v]
            else
                colors.palette240[v - 16],
        };
    }

    pub fn setColor(self: *Self, comptime part: ColorPart, c: Color) void {
        @field(self.current, @tagName(part)) = self.convertColor(c);

        const bg = self.current.background;
        if (part == .background or part == .foreground) {
            const fg = self.current.foreground;
            self.current.dim_foreground = fg.mix(bg, 0.75);
        }
        if (part == .background or part == .underline) {
            const ul = self.current.underline;
            self.current.dim_underline = ul.mix(bg, 0.75);
        }
    }

    pub fn resetColor(self: *Self, comptime part: ColorPart) void {
        @field(self.current, @tagName(part)) = @field(self.default, @tagName(part));
        if (part == .background) return; // if foreground or underline, we need to set dim variants too
        @field(self.current, "dim_" ++ @tagName(part)) = @field(self.default, "dim_" ++ @tagName(part));
    }
};

// INITIALIZATION

pub fn init() void {
    const framebuffers = limine.fb.response;
    // probably unreachable but halt just in case
    if (framebuffers.count == 0) @import("util.zig").halt();

    // start logging to the smallest framebuffer
    // when we bring up more, they'll mirror this one
    var smallest = framebuffers.entries[0];

    for (1..framebuffers.count) |i| {
        const this = framebuffers.entries[i];

        if (this.width < smallest.width and
            this.height < smallest.height)
            smallest = this;
    }

    info = .init(smallest.modes[0]);
    buffer = .init(smallest.ptr, smallest.modes[0]);

    clear();
}

var virtual_mode: VideoMode = undefined;

/// Run this after memory structures initialized.
pub fn virtualize() void {
    const framebuffers = limine.fb.response;

    const physical_buffer = buffer;
    virtual_mode = physical_buffer.mode.*;
    // virtual framebuffer, don't use monitor pitch
    virtual_mode.pitch = virtual_mode.width * buffer.bytes;

    const virtual_vmem_size = virtual_mode.pitch * virtual_mode.height;
    const virtual_vmem = allocator.alloc(u8, virtual_vmem_size) catch unreachable;

    info = .init(&virtual_mode);
    buffer = Framebuffer.init(virtual_vmem.ptr, &virtual_mode);
    buffer.copy(&physical_buffer, null);
    virtual = .{};

    for (0..framebuffers.count) |i| {
        const mirror = framebuffers.entries[i];
        const mirror_fb = Framebuffer.init(mirror.ptr, mirror.modes[0]);
        addOutput(mirror_fb) catch break;
    }
}
