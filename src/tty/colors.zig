const std = @import("std");

const color = @import("../gfx/color.zig");
pub const RgbSize = color.RgbSize;
pub const Rgb = color.Rgb;
pub const Hsl = color.Hsl;

pub const Type = enum { basic, @"256", hsl, rgb };
pub const FullType = union(Type) { basic, @"256", hsl, rgb: RgbSize };

pub const Color = union(Type) {
    basic: Basic,
    @"256": u8,
    hsl: Hsl,
    rgb: Rgb,

    pub fn TypePayload(comptime typ: Type) type {
        return switch (typ) {
            .basic => Basic,
            .@"256" => u8,
            .hsl => Hsl,
            .rgb => Rgb,
        };
    }

    pub fn FullTypePayload(comptime typ: FullType) type {
        return switch (typ) {
            .basic => Basic,
            .@"256" => u8,
            .hsl => Hsl,
            .rgb => |v| Rgb.SizePayload(v),
        };
    }
};

// 4-BIT COLOR

pub const Basic = enum(u4) {
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
    yellow,
    white,
};

// PALETTE

const Rgb24 = Rgb.Bpp24;

fn buildDimPalette(comptime len: usize, in: [len]Rgb24) [len]Rgb24 {
    @setEvalBranchQuota(10000);
    var out = in;
    for (out, 0..) |c, i| {
        const hsl = (Rgb{ .bpp24 = c }).toHsl();
        out[i] = Rgb.fromHsl(hsl.dim()).getSize(.bpp24);
    }
    return out;
}

// https://int10h.org/blog/2022/06/ibm-5153-color-true-cga-palette/
// using the canonical palette to fit in with emulators
// may be modified in framebuffer mode using ANSI escape codes
pub const palette16: [16]Rgb24 = .{
    Rgb24.fromHex(0x000000), // black
    Rgb24.fromHex(0x0000AA), // blue
    Rgb24.fromHex(0x00AA00), // green
    Rgb24.fromHex(0x00AAAA), // cyan
    Rgb24.fromHex(0xAA0000), // red
    Rgb24.fromHex(0xAA00AA), // magenta
    Rgb24.fromHex(0xAA5500), // brown
    Rgb24.fromHex(0xAAAAAA), // light gray
    Rgb24.fromHex(0x555555), // dark gray
    Rgb24.fromHex(0x5555FF), // light blue
    Rgb24.fromHex(0x55FF55), // light green
    Rgb24.fromHex(0x55FFFF), // light cyan
    Rgb24.fromHex(0xFF5555), // light red
    Rgb24.fromHex(0xFF55FF), // light magenta
    Rgb24.fromHex(0xFFFF55), // yellow
    Rgb24.fromHex(0xFFFFFF), // white
};

pub const dim_palette16 = buildDimPalette(16, palette16);

// upper part of the 256-color palette
// should not be modified in any mode
pub const palette240 = blk: {
    var out: [240]Rgb24 = undefined;

    for (0..6) |i|
        for (0..6) |j|
            for (0..6) |k| {
                const hex = (0x330000 * i) + (0x3300 * j) + (0x33 * k);
                out[k + (j * 6) + (i * 6 * 6)] = Rgb24.fromHex(hex);
            };

    for (0..24) |i|
        out[216 + i] = Rgb24.fromHex(0x080808 + 0x0A0A0A * i);

    break :blk out;
};

pub const dim_palette240 = buildDimPalette(240, palette240);

// PALETTE HANDLER

const Effects = @import("effects.zig").Effects;

// how similar are these colors?
inline fn compareHsl(self: Hsl, other: Hsl) f64 {
    const h = 1 - @abs(other.h - self.h);
    const s = 1 - @abs(other.s - self.s);
    const l = 1 - @abs(other.l - self.l);

    // importance: hue, lightness, saturation
    return h * 0.45 + s * 0.20 + l * 0.35;
}

// iterate through the static color palette and pick the closest one
pub fn hslToStatic(hsl: Hsl, palettes: *const Palettes, comptime upper: bool) if (upper) u8 else Basic {
    var closest: u8 = 0;
    var closest_score: f64 = 0.0;

    for (palettes.current16(), 0..) |rgb, i| {
        const score = compareHsl(hsl, rgb.toGeneric().toHsl());
        if (score > closest_score) {
            closest = i;
            closest_score = score;
        }
    }

    if (!upper) return @enumFromInt(closest);

    for (palettes.current240(), 0..) |rgb, i| {
        const score = compareHsl(hsl, rgb.toGeneric().toHsl());
        if (score > closest_score) {
            closest = i + 16;
            closest_score = score;
        }
    }

    return closest;
}

pub const Palettes = struct {
    effects: *Effects = undefined,
    // only 4-bit colors are mutable
    regular: [16]Rgb24 = palette16,
    dim: [16]Rgb24 = dim_palette16,

    pub inline fn current16(self: *const Palettes) *const [16]Rgb24 {
        return if (self.effects.get(.dim)) &self.dim else &self.regular;
    }

    pub inline fn current240(self: Palettes) *const [240]Rgb24 {
        return if (self.effects.get(.dim)) &dim_palette240 else &palette240;
    }

    pub inline fn convert(
        self: *const Palettes,
        comptime typ: Type,
        col: Color,
    ) Color.TypePayload(typ) {
        return switch (col) {
            .basic => |v| switch (typ) {
                .basic => v,
                .@"256" => @intFromEnum(v),
                .hsl => self.current16()[@intFromEnum(v)].toGeneric().toHsl(),
                .rgb => self.current16()[@intFromEnum(v)].toGeneric(),
            },

            .@"256" => |v| if (v < 16) switch (typ) {
                .@"256" => v,
                .basic => @enumFromInt(v),
                .hsl => self.current16()[v].toGeneric().toHsl(),
                .rgb => self.current16()[v].toGeneric(),
            } else switch (typ) {
                .@"256" => v,
                .basic => hslToStatic(self.current240()[v - 16].toGeneric().toHsl(), self, false),
                .hsl => self.current240()[v - 16].toGeneric().toHsl(),
                .rgb => self.current240()[v - 16].toGeneric(),
            },

            .hsl => |v| switch (typ) {
                .hsl => v,
                .basic => hslToStatic(v, self, false),
                .@"256" => hslToStatic(v, self, true),
                .rgb => Rgb.fromHsl(v),
            },

            .rgb => |v| switch (typ) {
                .rgb => v,
                .basic => hslToStatic(v.toHsl(), self, false),
                .@"256" => hslToStatic(v.toHsl(), self, true),
                .hsl => v.toHsl(),
            },
        };
    }
};
