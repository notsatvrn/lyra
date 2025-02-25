//! A simple framebuffer graphics implementation.

const std = @import("std");

const RGB = @import("color.zig").RGB;

const limine = @import("../limine.zig");
const VideoMode = limine.Framebuffer.VideoMode;

// FRAMEBUFFER

pub const Framebuffer = struct {
    buf: []u8,
    bytes: usize,
    mode: *const VideoMode,
    encoding: Encoding,

    const Encoding = struct {
        red_ratio_shift: u6,
        green_ratio_shift: u6,
        blue_ratio_shift: u6,
        red_location: u6,
        green_location: u6,
        blue_location: u6,
        red_mask: u64,
        green_mask: u64,
        blue_mask: u64,

        // INITIALIZATION

        pub inline fn init(mode: *const VideoMode) Encoding {
            // we don't support >12 bpp
            if (mode.red_mask_size > 12 or
                mode.green_mask_size > 12 or
                mode.blue_mask_size > 12)
                unreachable;

            return .{
                .red_ratio_shift = @truncate(12 - mode.red_mask_size),
                .green_ratio_shift = @truncate(12 - mode.green_mask_size),
                .blue_ratio_shift = @truncate(12 - mode.blue_mask_size),
                .red_location = @truncate(mode.red_mask_shift),
                .green_location = @truncate(mode.green_mask_shift),
                .blue_location = @truncate(mode.blue_mask_shift),
                .red_mask = (@as(u64, 1) << @truncate(mode.red_mask_size)) - 1,
                .green_mask = (@as(u64, 1) << @truncate(mode.green_mask_size)) - 1,
                .blue_mask = (@as(u64, 1) << @truncate(mode.blue_mask_size)) - 1,
            };
        }
    };

    const Self = @This();

    pub inline fn init(ptr: [*]u8, mode: *const VideoMode) Self {
        const bytes = (mode.bpp + 7) / 8;
        if (bytes < 2 or bytes > 5)
            unreachable;

        return .{
            .buf = ptr[0 .. mode.pitch * mode.height],
            .bytes = bytes,
            .mode = mode,
            .encoding = Encoding.init(mode),
        };
    }

    // MISC UTILITIES

    pub inline fn sameEncoding(self: Self, other: Self) bool {
        if (self.bytes != other.bytes) return false;

        inline for (std.meta.fields(Encoding)) |field| {
            const self_field: @FieldType(Encoding, field.name) = @field(self.encoding, field.name);
            const other_field: @FieldType(Encoding, field.name) = @field(other.encoding, field.name);
            if (self_field != other_field) return false;
        }

        return true;
    }

    // WRITING PIXELS

    pub inline fn makePixel(self: Self, color: RGB.BPP36) u64 {
        var r = @as(u64, color.r);
        var g = @as(u64, color.g);
        var b = @as(u64, color.b);

        r >>= self.encoding.red_ratio_shift;
        g >>= self.encoding.green_ratio_shift;
        b >>= self.encoding.blue_ratio_shift;

        r <<= self.encoding.red_location;
        g <<= self.encoding.green_location;
        b <<= self.encoding.blue_location;

        return r | g | b;
    }

    pub inline fn writePixelBytes(self: Self, comptime bytes: usize, pos: usize, pixel: u64) void {
        const Pixel = std.meta.Int(.unsigned, bytes * 8);
        const window: *[bytes]u8 = @ptrCast(self.buf[pos .. pos + bytes]);
        std.mem.writeInt(Pixel, window, @truncate(pixel), .little);
    }

    pub inline fn writePixel(self: Self, pos: usize, pixel: u64) void {
        @setEvalBranchQuota(10000);

        switch (self.bytes) {
            inline 2...5 => |bytes| self.writePixelBytes(bytes, pos, pixel),
            else => unreachable,
        }
    }

    pub inline fn writePixelNTimes(self: Self, pos: usize, pixel: u64, n: usize) void {
        var offset: usize = pos;
        switch (self.bytes) {
            inline 2...5 => |bytes| for (0..n) |_| {
                self.writePixelBytes(bytes, offset, pixel);
                offset += bytes;
            },
            else => unreachable,
        }
    }

    pub inline fn drawRect(self: Self, pos: usize, pixel: u64, w: usize, h: usize) void {
        var row: usize = pos;
        switch (self.bytes) {
            inline 2...5 => |bytes| for (0..h) |_| {
                var offset: usize = row;
                for (0..w) |_| {
                    self.writePixelBytes(bytes, offset, pixel);
                    offset += bytes;
                }
                row += self.mode.pitch;
            },
            else => unreachable,
        }
    }

    pub inline fn writeColor(self: Self, pos: usize, color: RGB.BPP36) void {
        self.writePixel(pos, self.makePixel(color));
    }

    pub inline fn clear(self: Self) void {
        @memset(self.buf, 0);
    }

    // READING PIXELS

    pub inline fn readColor(self: Self, pos: usize) RGB.BPP36 {
        var pixel: u64 = 0;

        switch (self.bytes) {
            inline 2...5 => |bytes| {
                const Pixel = std.meta.Int(.unsigned, bytes * 8);
                const window: *const [bytes]u8 = @ptrCast(self.buf[pos .. pos + bytes]);
                pixel = @as(u64, std.mem.readInt(Pixel, window, .little));
            },
            else => unreachable,
        }

        var r = pixel >> self.encoding.red_location;
        var g = pixel >> self.encoding.green_location;
        var b = pixel >> self.encoding.blue_location;

        r &= self.encoding.red_mask;
        g &= self.encoding.green_mask;
        b &= self.encoding.blue_mask;

        r <<= self.encoding.red_ratio_shift;
        g <<= self.encoding.green_ratio_shift;
        b <<= self.encoding.blue_ratio_shift;

        return .{
            .r = @truncate(r),
            .g = @truncate(g),
            .b = @truncate(b),
        };
    }
};
