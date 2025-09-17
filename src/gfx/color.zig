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

pub const Rgb = struct {
    r: u12,
    g: u12,
    b: u12,

    // 8-BPC CONVERSIONS

    pub const Bpc8 = packed struct(u24) { b: u8, g: u8, r: u8 };

    inline fn upscale(bpc8: u8) u12 {
        var out = @as(u12, bpc8) << 4;
        // duplicate the lower 4 bits
        out |= @as(u12, bpc8 & 0xF);
        return out;
    }

    pub inline fn fromBpc8(bpc8: Bpc8) Rgb {
        return .{
            .r = upscale(bpc8.r),
            .g = upscale(bpc8.g),
            .b = upscale(bpc8.b),
        };
    }

    pub inline fn fromHex(hex: u24) Rgb {
        return Rgb.fromBpc8(@bitCast(hex));
    }

    pub inline fn toBpc8(self: Rgb) Bpc8 {
        return .{
            .r = @truncate(self.r >> 4),
            .g = @truncate(self.g >> 4),
            .b = @truncate(self.b >> 4),
        };
    }

    // MIXING

    pub fn mix(a: Rgb, b: Rgb, ratio: f64) Rgb {
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

    // RGB / HSL CONVERSIONS
    // https://gist.github.com/ciembor/1494530

    pub fn toHsl(self: Rgb) Hsl {
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

    fn hueToRgb(p: f64, q: f64, t: f64) f64 {
        var t2 = t;
        if (t < 0) t2 += 1;
        if (t > 1) t2 -= 1;
        if (t2 < 1.0 / 6.0) return p + (q - p) * 6 * t2;
        if (t2 < 1.0 / 2.0) return q;
        if (t2 < 2.0 / 3.0) return p + (q - p) * (2.0 / 3.0 - t2) * 6;
        return p;
    }

    pub fn fromHsl(hsl: Hsl) Rgb {
        var result = Rgb{ .r = 0, .g = 0, .b = 0 };

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
