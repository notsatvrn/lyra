const std = @import("std");

const color = @import("../gfx/color.zig");
pub const RgbSize = color.RgbSize;
pub const Rgb = color.Rgb;
const Hsl = color.Hsl;

pub const Type = enum { basic, @"256", rgb };
pub const FullType = union(Type) { basic, @"256", rgb: RgbSize };

pub const Color = union(Type) {
    basic: Basic,
    @"256": u8,
    rgb: Rgb,

    pub fn TypePayload(comptime typ: Type) type {
        return switch (typ) {
            .basic => Basic,
            .@"256" => u8,
            .rgb => Rgb,
        };
    }

    pub fn FullTypePayload(comptime typ: FullType) type {
        return switch (typ) {
            .basic => Basic,
            .@"256" => u8,
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

    pub inline fn dim(self: Basic) Basic {
        return switch (self) {
            .light_gray => .dark_gray,
            .dark_gray => .black,
            .light_blue => .blue,
            .light_green => .green,
            .light_cyan => .cyan,
            .light_red => .red,
            .light_magenta => .magenta,
            .yellow => .brown,
            .white => .light_gray,
            // nothing darker
            else => self,
        };
    }

    pub inline fn bright(self: Basic) Basic {
        return switch (self) {
            .black => .dark_gray,
            .dark_gray => .light_gray,
            .blue => .light_blue,
            .green => .light_green,
            .cyan => .light_cyan,
            .red => .light_red,
            .magenta => .light_magenta,
            .brown => .yellow,
            // nothing brighter
            else => self,
        };
    }
};

// PALETTE

const Rgb24 = Rgb.Bpp24;

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

// INTER-PALETTE MAPPING

/// Used in VGA text mode because 256-color is not available.
pub const map_240_16 = blk: {
    var out: [240]Basic = undefined;
    for (0..240) |i| {
        const hsl = palette240[i].toBpp36().toHsl();
        out[i] = hslClosestBasic(hsl);
    }
    break :blk out;
};

inline fn hslClosestBasic(hsl: Hsl) Basic {
    @setEvalBranchQuota(100000);
    var closest: Basic = .black;
    var closest_score: f64 = 0.0;

    for (0..16) |i| {
        const score = hsl.compare(palette16[i].toBpp36().toHsl());
        if (score > closest_score) {
            closest = @enumFromInt(i);
            closest_score = score;
        }
    }

    return closest;
}

pub fn closestBasic(c: Color) Basic {
    return switch (c) {
        .basic => |v| v,
        .@"256" => |v| if (v < 16)
            @enumFromInt(v)
        else
            map_240_16[v - 16],
        .rgb => |v| hslClosestBasic(v.toHsl()),
    };
}
