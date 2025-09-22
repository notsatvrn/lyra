//! A simple framebuffer graphics implementation.

const std = @import("std");

const Rgb = @import("color.zig").Rgb;

const limine = @import("../limine.zig");
const VideoMode = limine.Framebuffer.VideoMode;

// FRAMEBUFFER

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

pub fn init(ptr: [*]u8, mode: *const VideoMode) Self {
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

// WRITING PIXELS

pub fn makePixel(self: *const Self, color: Rgb) u64 {
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

pub fn writePixel(self: *const Self, pos: usize, pixel: u64) void {
    switch (self.bytes) {
        inline 2...5 => |bytes| {
            const Pixel = std.meta.Int(.unsigned, bytes * 8);
            const window: *[bytes]u8 = @ptrCast(self.buf[pos .. pos + bytes]);
            std.mem.writeInt(Pixel, window, @truncate(pixel), .little);
        },
        else => unreachable,
    }
}

pub inline fn writePixelNTimes(self: *const Self, pos: usize, pixel: u64, n: usize) void {
    for (0..n) |i| self.writePixel(pos + (self.bytes * i), pixel);
}

pub inline fn drawRect(self: *const Self, pos: usize, pixel: u64, w: usize, h: usize) void {
    for (0..h) |i| self.writePixelNTimes(pos + (self.mode.pitch * i), pixel, w);
}

pub inline fn writeColor(self: *const Self, pos: usize, color: Rgb) void {
    self.writePixel(pos, self.makePixel(color));
}

pub inline fn clear(self: *const Self) void {
    @memset(self.buf, 0);
}

// READING PIXELS

pub fn readColor(self: *const Self, pos: usize) Rgb {
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

// COPYING

const Rect = @import("../gfx.zig").Rect;

/// dst and src cannot be the same buffer!
pub fn copy(noalias dst: *const Self, noalias src: *const Self, bounds: ?Rect) void {
    const width = if (bounds) |b| b.dimensions[0] else @min(src.mode.width, dst.mode.width);
    const height = if (bounds) |b| b.dimensions[1] else @min(src.mode.height, dst.mode.height);

    var dst_offset: usize = 0;
    var src_offset: usize = 0;
    if (bounds) |b| { // move offsets to the bounds corner
        dst_offset += (b.corner[0] * dst.bytes) + (b.corner[1] * dst.mode.pitch);
        src_offset += (b.corner[0] * src.bytes) + (b.corner[1] * src.mode.pitch);
    }

    if (std.meta.eql(dst.encoding, src.encoding)) {
        const end = src.bytes * width;

        for (0..height) |_| {
            // same encoding, copy the whole row
            const dst_buf = dst.buf[dst_offset .. dst_offset + end];
            const src_buf = src.buf[src_offset .. src_offset + end];
            @memcpy(dst_buf, src_buf);
            dst_offset += dst.mode.pitch;
            src_offset += src.mode.pitch;
        }
    } else {
        const dst_diff = dst.mode.pitch - (dst.bytes * width);
        const src_diff = src.mode.pitch - (src.bytes * width);

        for (0..height) |_| {
            // re-encode the row
            for (0..width) |_| {
                dst.writeColor(dst_offset, src.readColor(src_offset));
                dst_offset += dst.bytes;
                src_offset += src.bytes;
            }
            dst_offset += dst_diff;
            src_offset += src_diff;
        }
    }
}
