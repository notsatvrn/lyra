const std = @import("std");

pub const TextMode = @import("tty/TextMode.zig");
const fb = @import("tty/framebuffer.zig");

pub const colors = @import("tty/colors.zig");
pub const Color = colors.Color;
const Palettes = colors.Palettes;

pub const effects = @import("tty/effects.zig");
const ColorPart = effects.ColorPart;
const Effects = effects.Effects;
const ANSI = effects.ANSI;

const limine = @import("limine.zig");
const VideoMode = limine.Framebuffer.VideoMode;

pub var out: Output = undefined;
var render = RenderState.init();

pub const OutputType = enum { text_mode, rawfb, virtfb };
pub const Output = union(OutputType) {
    text_mode: TextMode,
    rawfb: fb.Terminal,
    virtfb: fb.AdvancedTerminal,

    const Self = @This();

    // INITIALIZATION

    pub fn initTextMode(addr: usize) Output {
        return .{ .text_mode = TextMode.initAddr(addr) };
    }

    pub fn initRawFB(ptr: [*]u8, mode: *const VideoMode) Output {
        return .{ .rawfb = fb.Terminal.init(ptr, mode) };
    }

    pub fn initVirtFB(mode: *const VideoMode) !Output {
        return .{ .virtfb = try fb.AdvancedTerminal.initVirtual(mode) };
    }

    // BASIC OPERATIONS

    fn put(self: *Self, char: u8) void {
        if (switch (self.*) {
            inline .text_mode => false,
            inline .rawfb => |*buf| buf.render.checkChar(char),
            inline .virtfb => |*buf| buf.base.render.checkChar(char),
        }) return;

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

    //pub inline fn print(self: *Self, string: []const u8) void {
    //    for (string) |c| self.put(c);
    //}

    pub inline fn print(self: *Self, string: []const u8) void {
        switch (self.*) {
            inline else => |*v| v.print(string),
        }
    }

    pub fn clear(self: *Self) void {
        switch (self.*) {
            inline else => |*v| v.clear(),
        }
    }

    // FORMATTING

    fn write(self: *Self, bytes: []const u8) error{}!usize {
        self.print(bytes);
        return bytes.len;
    }

    pub const Writer = std.io.Writer(*Self, error{}, write);

    pub inline fn writer(self: *Self) Writer {
        return .{ .context = self };
    }

    pub inline fn printf(self: *Self, comptime fmt: []const u8, args: anytype) void {
        self.writer().print(fmt, args) catch unreachable;
    }
};

pub inline fn sync() void {
    if (out == .virtfb)
        out.virtfb.updateMirrors();
}

// The current rendering state of the tty.
// Handles colors, effects, and ANSI escape sequences.
pub const RenderState = struct {
    // zig fmt: off
    foreground_color : Color = .{ .basic = .light_gray },
    background_color : Color = .{ .basic = .black      },
    underline_color  : Color = .{ .basic = .light_gray },

    effects  : Effects  = .{},
    palettes : Palettes = .{},

    parsing : ?Parsing = null,
    // zig fmt: on

    const Self = @This();

    const Parsing = struct {};

    pub inline fn init() Self {
        var s = Self{};
        s.palettes.effects = &s.effects;
        return s;
    }

    pub fn checkChar(self: *Self, char: u8) bool {
        // do nothing for now
        // TODO: introduce ANSI escape code parser
        if (self.parsing) |p| {
            _ = p;

            switch (char) {
                'A' | 'B' | 'C' | 'D' | 'E' | 'F' | 'f' | 'G' | 'H' | 'h' | 'i' | 'J' | 'K' | 'l' | 'm' | 'n' | 'S' | 's' | 'T' | 'u' => self.parsing = null,
                else => {},
            }
        } else if (char == ANSI.esc) {
            self.parsing = .{};
        } else return false;

        return true;
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
