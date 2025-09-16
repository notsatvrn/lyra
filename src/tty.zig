const std = @import("std");

pub const Framebuffer = @import("tty/Framebuffer.zig");
pub const TextMode = @import("tty/TextMode.zig");

pub const colors = @import("tty/colors.zig");
pub const Color = colors.Color;

pub const effects = @import("tty/effects.zig");
const ColorPart = effects.ColorPart;
const Effects = effects.Effects;
const Ansi = effects.Ansi;

const limine = @import("limine.zig");
const VideoMode = limine.Framebuffer.VideoMode;

// OUTPUTS

pub const OutputType = enum { text, fb };
pub const Output = union(OutputType) {
    text: TextMode,
    fb: Framebuffer,
};

pub var output = Output{ .text = .{} };

// BASICS

pub fn print(string: []const u8) void {
    switch (output) {
        .text => |*text| text.print(string),
        .fb => |*fb| fb.print(string),
    }
}

pub fn clear() void {
    switch (output) {
        .text => |*text| text.clear(),
        .fb => |*fb| fb.clear(),
    }
}

pub fn sync() void {
    if (output == .fb) output.fb.sync();
}

// STATE

const gfx = @import("gfx.zig");
const Rgb24 = gfx.color.Rgb.Bpp24;
const AnsiParser = effects.AnsiParser;

pub var state = State{};

// The current rendering state of the tty.
// Handles colors, effects, and ANSI escapes.
pub const State = struct {
    default: Colors = .{},
    current: Colors = .{},
    effects: Effects = .{},
    palette: [16]Rgb24 = colors.palette16,
    ansi_parser: AnsiParser = .{},

    pub const Colors = struct {
        // zig fmt: off
        foreground     : Color = .{ .basic = .light_gray },
        dim_foreground : Color = .{ .basic = .dark_gray  },
        underline      : Color = .{ .basic = .light_gray },
        dim_underline  : Color = .{ .basic = .dark_gray  },
        background     : Color = .{ .basic = .black      },
        // zig fmt: on

        pub fn rgbify(self: *Colors, palette: *const [16]Rgb24) void {
            const fg = palette[@intFromEnum(self.foreground.basic)];
            const bg = palette[@intFromEnum(self.background.basic)];
            const ul = palette[@intFromEnum(self.underline.basic)];
            self.foreground = .{ .rgb = fg.toBpp36().toGeneric() };
            self.background = .{ .rgb = bg.toBpp36().toGeneric() };
            self.underline = .{ .rgb = ul.toBpp36().toGeneric() };
            self.dim_foreground = .{ .rgb = self.foreground.rgb.bpp36.mix(self.background.rgb.bpp36, 0.75).toGeneric() };
            self.dim_underline = .{ .rgb = self.underline.rgb.bpp36.mix(self.background.rgb.bpp36, 0.75).toGeneric() };
        }
    };

    const Self = @This();

    pub fn checkChar(self: *Self, char: u8) bool {
        return self.ansi_parser.checkChar(char);
    }

    pub fn getPart(self: Self, comptime part: ColorPart) Color {
        if (part == .background) return self.current.background;

        const dim = self.effects.get(.dim);

        return switch (@as(OutputType, output)) {
            .text => text: {
                const bright = self.effects.get(.bold);
                const base = @field(self.current, @tagName(part)).basic;
                // dim + bright = normal. looks right when surrounded with dim text
                if (dim == bright) break :text .{ .basic = base };
                if (dim) break :text .{ .basic = base.dim() };
                break :text .{ .basic = base.bright() };
            },
            .fb => fb: {
                // for framebuffer console we actually pre-calculate the dim value
                if (dim) break :fb @field(self.current, "dim_" ++ @tagName(part));
                break :fb @field(self.current, @tagName(part));
            },
        };
    }

    inline fn convertColor(self: Self, c: Color) Color {
        if (output == .text) return .{ .basic = colors.closestBasic(c) };
        // now output is framebuffer
        return .{ .rgb = switch (c) {
            .rgb => |v| v.getSize(.bpp36).toGeneric(),
            .basic => |v| self.palette[@intFromEnum(v)].toBpp36().toGeneric(),
            .@"256" => |v| (if (v < 16)
                self.palette[v]
            else
                colors.palette240[v - 16]).toBpp36().toGeneric(),
        } };
    }

    pub fn setPart(self: *Self, comptime part: ColorPart, c: Color) void {
        @field(self.current, @tagName(part)) = self.convertColor(c);
        if (output == .text) return; // don't need to set dim variants on text console

        const bg = self.current.background.rgb;
        if (part == .background or part == .foreground) {
            const fg = self.current.foreground.rgb;
            self.current.dim_foreground = .{ .rgb = fg.bpp36.mix(bg.bpp36, 0.75).toGeneric() };
        }
        if (part == .background or part == .underline) {
            const ul = self.current.underline.rgb;
            self.current.dim_underline = .{ .rgb = ul.bpp36.mix(bg.bpp36, 0.75).toGeneric() };
        }
    }

    pub fn resetPart(self: *Self, comptime part: ColorPart) void {
        @field(self.current, @tagName(part)) = @field(self.default, @tagName(part));
        if (output == .text) return; // don't need to set dim variants on text console
        if (part == .background) return; // if foreground or underline, we need to set dim variants too
        @field(self.current, "dim_" ++ @tagName(part)) = @field(self.default, "dim_" ++ @tagName(part));
    }
};

// INITIALIZATION

pub fn init() void {
    const framebuffers = limine.fb.response;
    if (framebuffers.count > 0) {
        // start logging to the smallest framebuffer
        // when we bring up more, they'll mirror this one
        var smallest = framebuffers.entries[0];

        for (1..framebuffers.count) |i| {
            const this = framebuffers.entries[i];

            if (this.width < smallest.width and
                this.height < smallest.height)
                smallest = this;
        }

        const fb = Framebuffer.init(smallest.ptr, smallest.modes[0]);
        output = .{ .fb = fb };

        state.default.rgbify(&state.palette);
        state.current = state.default;
    }

    clear();
}

var vfb_mode: VideoMode = undefined;

/// Run this after memory structures initialized.
pub fn initDoubleBuffering() void {
    const framebuffers = limine.fb.response;
    if (framebuffers.count == 0) return;

    const smallest = &output.fb;
    vfb_mode = smallest.buffer.mode.*;
    // virtual framebuffer, don't use monitor pitch
    vfb_mode.pitch = vfb_mode.width * smallest.buffer.bytes;
    var fb = Framebuffer.initVirtual(&vfb_mode) catch return;

    fb.cursor = smallest.cursor;
    fb.buffer.copy(&smallest.buffer, null);

    for (0..framebuffers.count) |i| {
        const mirror = framebuffers.entries[i];
        const mirror_fb = gfx.Framebuffer.init(mirror.ptr, mirror.modes[0]);
        fb.addOutput(mirror_fb) catch break;
    }

    output.fb = fb;
}
