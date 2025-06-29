const std = @import("std");

pub const Hsl = packed struct {
    h: f64,
    s: f64,
    l: f64,

    pub inline fn dim(self: Hsl) Hsl {
        return .{ .h = self.h, .s = self.s * 0.75, .l = self.l * 0.75 };
    }

    // CONVERSIONS

    pub inline fn toRgb(self: Hsl) Rgb {
        return Rgb.fromHsl(self);
    }

    pub inline fn fromRgb(rgb: Rgb) Hsl {
        return rgb.toHsl();
    }
};

pub const RgbSize = enum(u16) {
    // "true color"
    bpp24 = 24,
    // "deep color"
    bpp36 = 36,
};

pub const Rgb = union(RgbSize) {
    bpp24: Bpp24,
    bpp36: Bpp36,

    pub fn SizePayload(size: RgbSize) type {
        return switch (size) {
            .bpp24 => Bpp24,
            .bpp36 => Bpp36,
        };
    }

    pub const Bpp24 = struct {
        b: u8,
        g: u8,
        r: u8,

        pub inline fn toGeneric(self: Bpp24) Rgb {
            return .{ .bpp24 = self };
        }

        pub inline fn fromHex(hex: u24) Bpp24 {
            return .{
                .r = @truncate(hex >> 16),
                .g = @truncate(hex >> 8),
                .b = @truncate(hex),
            };
        }
    };

    // HSL conversion algos from https://gist.github.com/ciembor/1494530
    pub const Bpp36 = struct {
        b: u12,
        g: u12,
        r: u12,

        pub inline fn toGeneric(self: Bpp36) Rgb {
            return .{ .bpp36 = self };
        }

        // color maximums

        const cmax = std.math.maxInt(u12);
        const cmax_f: f64 = @floatFromInt(cmax);

        // Hsl -> Rgb

        pub fn toHsl(self: Bpp36) Hsl {
            const r = @as(f64, @floatFromInt(self.r)) / cmax_f;
            const g = @as(f64, @floatFromInt(self.g)) / cmax_f;
            const b = @as(f64, @floatFromInt(self.b)) / cmax_f;

            const max = @max(r, @max(g, b));
            const min = @min(r, @min(g, b));

            const l = (max + min) / 2;
            var h = l;
            var s = l;

            if (max == min) {
                h = 0;
                s = 0;
            } else {
                const diff = max - min;

                h = if (max == r)
                    (g - b) / diff + @as(f64, if (g < b) 6.0 else 0.0)
                else if (max == g)
                    (b - r) / diff + 2.0
                else if (max == b)
                    (r - g) / diff + 4.0
                else
                    unreachable;

                h /= 6;

                s = if (l > 0.5) diff / (2 - max - min) else diff / (max + min);
            }

            return .{ .h = h, .s = s, .l = l };
        }

        // Rgb -> Hsl

        fn hueToRgb(p: f64, q: f64, t: f64) f64 {
            var t2 = t;
            if (t < 0) t2 += 1;
            if (t > 1) t2 -= 1;
            if (t2 < 1.0 / 6.0) return p + (q - p) * 6 * t2;
            if (t2 < 1.0 / 2.0) return q;
            if (t2 < 2.0 / 3.0) return p + (q - p) * (2.0 / 3.0 - t2) * 6;
            return p;
        }

        pub fn fromHsl(hsl: Hsl) Bpp36 {
            var result = Bpp36{ .r = 0, .g = 0, .b = 0 };

            if (hsl.s == 0) {
                result.r = @intFromFloat(hsl.l * cmax_f);
                result.g = @intFromFloat(hsl.l * cmax_f);
                result.b = @intFromFloat(hsl.l * cmax_f);
            } else {
                const s = hsl.s;
                const l = hsl.l;

                const q = if (l < 0.5) l * (1 + s) else l + s - l * s;
                const p = 2 * l - q;

                result.r = @intFromFloat(hueToRgb(p, q, hsl.h + 1.0 / 3.0) * cmax_f);
                result.g = @intFromFloat(hueToRgb(p, q, hsl.h) * cmax_f);
                result.b = @intFromFloat(hueToRgb(p, q, hsl.h - 1.0 / 3.0) * cmax_f);
            }

            return result;
        }
    };

    // COMMON CONVERSIONS

    pub inline fn toHsl(self: Rgb) Hsl {
        return self.getSize(.bpp36).toHsl();
    }

    pub inline fn fromHsl(hsl: Hsl) Rgb {
        return .{ .bpp36 = Bpp36.fromHsl(hsl) };
    }

    pub inline fn fromHex(hex: u24) Rgb {
        return .{ .bpp24 = Bpp24.fromHex(hex) };
    }

    // SCALING CONVERSIONS

    pub inline fn getSize(self: Rgb, comptime size: RgbSize) SizePayload(size) {
        switch (self) {
            inline else => |v, src_size| {
                if (src_size == size) return v;

                const src_size_bpc = @intFromEnum(src_size) / 3;
                const dst_size_bpc = @intFromEnum(size) / 3;
                const SrcColType = std.meta.Int(.unsigned, src_size_bpc);
                const DstColType = std.meta.Int(.unsigned, dst_size_bpc);
                const src_cmax = std.math.maxInt(SrcColType);
                const dst_cmax = std.math.maxInt(DstColType);

                if (src_size_bpc < dst_size_bpc) {
                    // upscaling, multiply by ratio
                    const ratio = dst_cmax / src_cmax;
                    return .{
                        .r = @as(DstColType, v.r) * ratio,
                        .g = @as(DstColType, v.g) * ratio,
                        .b = @as(DstColType, v.b) * ratio,
                    };
                } else {
                    // downscaling, divide by ratio
                    const ratio = src_cmax / dst_cmax;
                    return .{
                        .r = @truncate(v.r / ratio),
                        .g = @truncate(v.g / ratio),
                        .b = @truncate(v.b / ratio),
                    };
                }
            },
        }
    }
};
