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
            .cols = mode.width / 8,
            .rows = mode.height / 16,
            .hpad = @truncate(mode.width % 8),
            .vpad = @truncate(mode.height % 16),
        };
    }
};

var font: *const [256][16]u8 = &oldschoolPGC;
var buffer: Framebuffer = undefined;

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
    for (0..8) |i| {
        const bit: u3 = @truncate(7 - i);
        const set = (data >> bit & 1) == 1;
        if (replace) {
            buffer.writePixel(offset, if (set) fg else bg);
        } else if (set) buffer.writePixel(offset, fg);
        offset += buffer.bytes;
    }
}

inline fn writeChar(c: u8) void {
    const pitch = buffer.mode.pitch;

    const x = cursor.col * 8;
    const y = cursor.row * 16;

    var offset = (x * buffer.bytes) + (y * pitch);
    cursor.col += 1;

    if (cursor.col - 1 > info.cols) return;

    if (virtual) |*v| v.damage.add(.{
        .corner = .{ x, y },
        .dimensions = .{ 8, 16 },
    });

    const bg = getPixel(.background);

    // fast path for hidden
    if (state.effects.get(.hidden))
        return buffer.drawRect(offset, bg, 8, 16);

    // get character data and apply some effects

    var data = font[c];

    if (state.effects.get(.bold)) {
        inline for (data, 0..) |r, i|
            data[i] |= r << 1;
    }

    if (state.effects.get(.overline)) data[1] = 0xFF;
    if (state.effects.get(.strikethru)) data[7] = 0xFF;

    // write the character!

    const fg = getPixel(.foreground);

    inline for (data) |row| {
        writeCharRow(offset, row, fg, bg, true);
        offset += pitch;
    }

    // we support custom underline color using \e[58...m

    const underline = state.effects.get(.underline) orelse return;

    offset -= pitch * 2;
    const color = getPixel(.underline);

    switch (underline) {
        .single => buffer.writePixelNTimes(offset, color, 8),
        .double => {
            offset -= pitch;
            buffer.writePixelNTimes(offset, color, 8);
            offset += pitch * 2;
            buffer.writePixelNTimes(offset, color, 8);
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

pub fn put(char: u8) void {
    if (state.checkChar(char)) return;
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
    const line_size = buffer.mode.pitch * 16;
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
            info.cols * 8,
            info.rows * 16,
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
    ansi_parser: AnsiParser = .{},

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

    const Self = @This();

    pub fn checkChar(self: *Self, char: u8) bool {
        return self.ansi_parser.checkChar(char);
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
