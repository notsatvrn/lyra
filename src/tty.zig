const std = @import("std");

pub const Framebuffer = @import("tty/Framebuffer.zig");
pub const TextMode = @import("tty/TextMode.zig");

pub const colors = @import("tty/colors.zig");
pub const Color = colors.Color;
const Palettes = colors.Palettes;

pub const effects = @import("tty/effects.zig");
const ColorPart = effects.ColorPart;
const Effects = effects.Effects;
const Ansi = effects.Ansi;

const limine = @import("limine.zig");
const VideoMode = limine.Framebuffer.VideoMode;

// OUTPUTS

pub const Output = union(enum) {
    text: TextMode,
    fb: Framebuffer,
};

pub var output = Output{ .text = .{} };
pub var state: RenderState = undefined;

// BASICS

pub inline fn print(string: []const u8) void {
    switch (output) {
        .text => |*term| term.print(string),
        .fb => |*fb| fb.print(string),
    }
}

pub inline fn clear() void {
    switch (output) {
        .text => |*term| term.clear(),
        .fb => |*fb| fb.clear(),
    }
}

pub inline fn sync() void {
    if (output == .fb) output.fb.sync();
}

// FORMATTING

fn write(_: *const void, bytes: []const u8) error{}!usize {
    print(bytes);
    return bytes.len;
}

pub const Writer = std.io.Writer(*const void, error{}, write);

pub inline fn writer() Writer {
    return .{ .context = undefined };
}

pub inline fn printf(comptime fmt: []const u8, args: anytype) void {
    writer().print(fmt, args) catch unreachable;
}

// RENDER STATE

pub var render_ansi = false;

// The ANSI escape parser used by all TTY implementations
pub const AnsiParser = struct {
    parsing: ?Parsing = null,
    nop: bool = false,

    const Self = @This();

    const Parsing = struct {
        nop: bool = false,
    };

    pub fn checkChar(self: *Self, char: u8) bool {
        // TODO: for now it's always a nop, but we need a parser
        if (self.parsing) |p| {
            self.parsing = null;
            if (p.nop) {
                switch (char) {
                    'A' | 'B' | 'C' | 'D' | 'E' | 'F' | 'f' | 'G' | 'H' | 'h' | 'i' | 'J' | 'K' | 'l' | 'm' | 'n' | 'S' | 's' | 'T' | 'u' => self.parsing = null,
                    else => {},
                }
            }
        } else if (char == Ansi.esc) {
            self.parsing = .{ .nop = self.nop or !render_ansi };
        } else return false;

        return true;
    }
};

// The current rendering state of the tty.
// Handles colors, effects, and ANSI escapes.
pub const RenderState = struct {
    // zig fmt: off
    foreground_color : Color = .{ .basic = .light_gray },
    background_color : Color = .{ .basic = .black      },
    underline_color  : Color = .{ .basic = .light_gray },

    effects  : Effects  = .{},
    palettes : Palettes = .{},

    ansi_parser : AnsiParser = .{},
    // zig fmt: on

    const Self = @This();

    const Parsing = struct {};

    pub inline fn init() Self {
        var s = Self{};
        s.palettes.effects = &s.effects;
        return s;
    }

    pub inline fn checkChar(self: *Self, char: u8) bool {
        return self.ansi_parser.checkChar(char);
    }

    pub inline fn getColor(
        self: Self,
        comptime typ: colors.FullType,
        comptime col: ColorPart,
    ) Color.FullTypePayload(typ) {
        const raw = switch (col) {
            .foreground => self.foreground_color,
            .background => self.background_color,
            .underline => self.underline_color,
        };

        return switch (typ) {
            inline .rgb => |size| self.palettes.convert(.rgb, raw).getSize(size),
            inline else => |_, t| self.palettes.convert(t, raw),
        };
    }
};
