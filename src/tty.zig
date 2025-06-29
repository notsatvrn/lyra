const std = @import("std");

const arch = @import("arch.zig");

pub const TextMode = @import("tty/TextMode.zig");
const fb = @import("tty/framebuffer.zig");
pub const Framebuffer = fb.AnyTerminal;

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

pub var framebuffer: ?Framebuffer = null;
pub var generic: ?Generic = null;
var render = RenderState.init();

pub const Generic = struct {
    ptr: *anyopaque,
    vtable: VTable,

    pub const VTable = struct {
        print: *const fn (*anyopaque, []const u8) void,
        clear: *const fn (*anyopaque) void,
    };
};

// BASICS

pub inline fn print(string: []const u8) void {
    if (framebuffer) |*term| term.print(string);
    if (generic) |*term| term.vtable.print(term.ptr, string);
}

pub inline fn clear() void {
    if (framebuffer) |*term| term.clear();
    if (generic) |*term| term.vtable.clear(term.ptr);
}

pub inline fn sync() void {
    if (framebuffer) |*term| term.sync();
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
            _ = p;
            if (self.nop) {
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
