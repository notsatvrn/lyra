const std = @import("std");

pub const Hsl = packed struct {
    h: f64,
    s: f64,
    l: f64,

    // CONVERSIONS

    pub inline fn toRgb(self: Hsl) Rgb {
        return Rgb.fromHsl(self);
    }

    pub inline fn fromRgb(rgb: Rgb) Hsl {
        return rgb.toHsl();
    }

    // COMPARISON

    pub fn compare(self: Hsl, other: Hsl) f64 {
        const h = 1 - @abs(other.h - self.h);
        const s = 1 - @abs(other.s - self.s);
        const l = 1 - @abs(other.l - self.l);

        // importance: hue, lightness, saturation
        return h * 0.45 + s * 0.20 + l * 0.35;
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

        inline fn upscale(bpp24: u8) u12 {
            var out = @as(u12, bpp24) << 4;
            // duplicate the lower 4 bits
            out |= @as(u12, bpp24 & 0xF);
            return out;
        }

        pub fn toBpp36(self: Bpp24) Bpp36 {
            return .{
                .r = upscale(self.r),
                .g = upscale(self.g),
                .b = upscale(self.b),
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

        pub fn toBpp24(self: Bpp36) Bpp24 {
            return .{
                // truncate the lower 4 bits
                .r = @truncate(self.r >> 4),
                .g = @truncate(self.g >> 4),
                .b = @truncate(self.b >> 4),
            };
        }

        // MIXING

        pub fn mix(a: Bpp36, b: Bpp36, ratio: f64) Bpp36 {
            const ap = @min(@max(ratio, 0.0), 1.0);
            const bp = 1.0 - ap;

            const ar = @as(f64, @floatFromInt(a.r)) * ap;
            const ag = @as(f64, @floatFromInt(a.g)) * ap;
            const ab = @as(f64, @floatFromInt(a.b)) * ap;

            const br = @as(f64, @floatFromInt(b.r)) * bp;
            const bg = @as(f64, @floatFromInt(b.g)) * bp;
            const bb = @as(f64, @floatFromInt(b.b)) * bp;

            return .{
                .r = @intFromFloat(ar + br),
                .g = @intFromFloat(ag + bg),
                .b = @intFromFloat(ab + bb),
            };
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
        return switch (self) {
            .bpp24 => |v| switch (size) {
                .bpp24 => v,
                .bpp36 => v.toBpp36(),
            },
            .bpp36 => |v| switch (size) {
                .bpp24 => v.toBpp24(),
                .bpp36 => v,
            },
        };
    }
};
