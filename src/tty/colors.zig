const std = @import("std");

const color = @import("../gfx/color.zig");
pub const Rgb = color.Rgb;
const Hsl = color.Hsl;

pub const Type = enum { basic, @"256", rgb };

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

    pub fn toAnsi(self: Basic, bg: bool) u8 {
        var out: u8 = @intFromEnum(self);
        if (out >= 8) out += 60 - 8;
        if (bg) out += 10;
        return out + 30;
    }
};

// PALETTE

// https://int10h.org/blog/2022/06/ibm-5153-color-true-cga-palette/
// using the canonical palette to fit in with emulators
// may be modified in framebuffer mode using ANSI escape codes
pub const palette16: [16]Rgb = .{
    Rgb.fromHex(0x000000), // black
    Rgb.fromHex(0x0000AA), // blue
    Rgb.fromHex(0x00AA00), // green
    Rgb.fromHex(0x00AAAA), // cyan
    Rgb.fromHex(0xAA0000), // red
    Rgb.fromHex(0xAA00AA), // magenta
    Rgb.fromHex(0xAA5500), // brown
    Rgb.fromHex(0xAAAAAA), // light gray
    Rgb.fromHex(0x555555), // dark gray
    Rgb.fromHex(0x5555FF), // light blue
    Rgb.fromHex(0x55FF55), // light green
    Rgb.fromHex(0x55FFFF), // light cyan
    Rgb.fromHex(0xFF5555), // light red
    Rgb.fromHex(0xFF55FF), // light magenta
    Rgb.fromHex(0xFFFF55), // yellow
    Rgb.fromHex(0xFFFFFF), // white
};

// upper part of the 256-color palette
// should not be modified in any mode
pub const palette240 = blk: {
    @setEvalBranchQuota(10000);
    var out: [240]Rgb = undefined;

    for (0..6) |i|
        for (0..6) |j|
            for (0..6) |k| {
                const hex = (0x330000 * i) + (0x3300 * j) + (0x33 * k);
                out[k + (j * 6) + (i * 6 * 6)] = Rgb.fromHex(hex);
            };

    for (0..24) |i|
        out[216 + i] = Rgb.fromHex(0x080808 + 0x0A0A0A * i);

    break :blk out;
};
