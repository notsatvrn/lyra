//! A framebuffer-based text-mode tty emulator.
//! Supports a wide range of text effects.

const std = @import("std");

const gfx = @import("../gfx.zig");
const Framebuffer = gfx.Framebuffer;
const AABB = gfx.AABB;

const super = @import("../tty.zig");
const RenderState = super.RenderState;
const ColorPart = super.effects.ColorPart;
const ANSI = super.effects.ANSI;
const RGB = super.colors.RGB;

const limine = @import("../limine.zig");
const VideoMode = limine.Framebuffer.VideoMode;

const memory = @import("../memory.zig");

const font = @import("fonts.zig").oldschoolPGC.data;

// COMMANDS

pub const Command = union(enum) {
    print: []const u8,
    ansi_esc: ANSI,
    scroll,
};

pub const Commands = std.DoublyLinkedList(Command);

// TERMINAL

pub const Terminal = struct {
    info: Info,
    buffer: Framebuffer,
    // console state
    render: RenderState,
    cursor: Cursor = .{},
    // command buffer
    cmd: ?Command = null,
    //cmds: ?*Commands = null,

    const Info = struct {
        // emulated text area res
        cols: usize,
        rows: usize,
        // text area padding
        // should always be black
        hpad: u8,
        vpad: u8,

        pub inline fn init(mode: *const VideoMode) Info {
            return .{
                .cols = mode.width / 8,
                .rows = mode.height / 16,
                .hpad = @truncate(mode.width % 8),
                .vpad = @truncate(mode.height % 16),
            };
        }
    };

    const Cursor = struct {
        row: usize = 0,
        col: usize = 0,
        show: bool = true,
    };

    const Self = @This();

    pub inline fn init(ptr: [*]u8, mode: *const VideoMode) Self {
        return .{
            .info = Info.init(mode),
            .buffer = Framebuffer.init(ptr, mode),
            .render = RenderState.init(),
        };
    }

    // PLACING CHARACTERS

    pub fn getPixel(self: Self, comptime part: ColorPart) u64 {
        const color = self.render.getColor(.{ .rgb = .bpp36 }, part);
        return self.buffer.makePixel(color);
    }

    inline fn writeCharRow(self: *Self, pos: usize, data: u8, fg: u64, bg: u64, comptime replace: bool) void {
        var offset: usize = pos;
        switch (self.buffer.bytes) {
            inline 2...5 => |bytes| for (0..8) |i| {
                const set = ((data >> @truncate(i)) & 1) == 1;
                if (replace) {
                    self.buffer.writePixelBytes(bytes, offset, if (set) fg else bg);
                } else if (set) self.buffer.writePixelBytes(bytes, offset, fg);
                offset += bytes;
            },
            else => unreachable,
        }
    }

    inline fn writeChar(self: *Self, c: u8) void {
        const pitch = self.buffer.mode.pitch;

        var offset = self.cursor.row * pitch * 16;
        offset += self.cursor.col * self.buffer.bytes * 8;
        self.cursor.col += 1;

        if (self.cursor.col - 1 > self.info.cols) return;

        const bg = self.getPixel(.background);

        // fast path for hidden
        if (self.render.effects.get(.hidden)) {
            self.buffer.drawRect(offset, bg, 8, 16);
            return;
        }

        // get character data and apply some effects

        var data = font[c];

        if (self.render.effects.get(.bold)) {
            inline for (data, 0..) |r, i|
                data[i] |= r << 1;
        }

        if (self.render.effects.get(.overline)) data[1] = 0xFF;
        if (self.render.effects.get(.strikethru)) data[7] = 0xFF;

        // write the character!

        const fg = self.getPixel(.foreground);

        inline for (data) |row| {
            self.writeCharRow(offset, row, fg, bg, true);
            offset += pitch;
        }

        // we support custom underline color using \e[58...m

        const underline = self.render.effects.get(.underline) orelse return;

        offset -= pitch * 2;
        const color = self.getPixel(.underline);

        switch (underline) {
            .single => self.buffer.writePixelNTimes(offset, color, 8),
            .double => {
                offset -= pitch;
                self.buffer.writePixelNTimes(offset, color, 8);
                offset += pitch * 2;
                self.buffer.writePixelNTimes(offset, color, 8);
            },
            .curly => {
                self.writeCharRow(offset, 0b10011001, color, undefined, false);
                offset += pitch;
                self.writeCharRow(offset, 0b01100110, color, undefined, false);
            },
            .dotted => self.writeCharRow(offset, 0b10101010, color, undefined, false),
            .dashed => self.writeCharRow(offset, 0b11101110, color, undefined, false),
        }
    }

    // SPECIAL CHARACTER HANDLING

    pub fn put(self: *Self, char: u8) void {
        if (self.render.checkChar(char)) return;
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

    pub inline fn print(self: *Self, string: []const u8) void {
        for (string) |c| self.put(c);
    }

    // SCROLLING / CLEARING

    inline fn scroll(self: *Self) void {
        if (self.cmd != null) {
            self.cmd = .scroll;
            return;
        }

        const line_size = self.buffer.mode.pitch * 16;
        const bottom_end = line_size * self.info.rows;
        const top_end = bottom_end - line_size;
        // Copy buffer data starting from the second line to the start.
        std.mem.copyForwards(u8, self.buffer.buf[0..top_end], self.buffer.buf[line_size..bottom_end]);
        // Clear the last line.
        @memset(self.buffer.buf[top_end..], 0);
        // Move the cursor up a line.
        self.cursor.row -= 1;
    }

    pub inline fn clear(self: *Self) void {
        self.buffer.clear();
        self.cursor.row = 0;
        self.cursor.col = 0;
    }
};

// ADVANCED TERMINAL

pub const AdvancedTerminal = struct {
    base: Terminal,
    buf: ?[]const u8 = null,
    // mirrored consoles
    mirrors: Mirrors = .{},
    // damage tracking
    damage: ?AABB = null,

    const Mirrors = std.ArrayListUnmanaged(Framebuffer);

    const Self = @This();

    pub inline fn initVirtual(mode: *const VideoMode) !Self {
        const buf = try memory.allocator.alloc(u8, mode.pitch * mode.height);
        var self = Self.init(buf.ptr, mode);
        self.buf = buf;
        return self;
    }

    pub inline fn init(ptr: [*]u8, mode: *const VideoMode) Self {
        var self = Self{ .base = Terminal.init(ptr, mode) };
        self.base.cmd = .scroll;
        return self;
    }

    // MIRRORING

    pub inline fn updateMirrors(self: *Self) void {
        // TODO: implement damage tracking
        //if (self.damage == null) return;

        const src = &self.base.buffer;

        for (self.mirrors.items) |*dst| {
            const height = @min(src.mode.height, dst.mode.height);
            const width = @min(src.mode.width, dst.mode.width);

            var dst_offset: usize = 0;
            var src_offset: usize = 0;

            if (src.sameEncoding(dst)) {
                // fast path for same encoder

                const end = src.bytes * width;

                for (0..height) |_| {
                    @memcpy(
                        dst.buf[dst_offset .. dst_offset + end],
                        src.buf[src_offset .. src_offset + end],
                    );

                    dst_offset += dst.mode.pitch;
                    src_offset += src.mode.pitch;
                }
            } else {
                // decode and encode again

                const dst_diff = dst.mode.pitch - (dst.bytes * width);
                const src_diff = src.mode.pitch - (src.bytes * width);

                for (0..height) |_| {
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

        self.damage = null;
    }

    pub inline fn initMirroring(self: *Self, old_buf: Framebuffer) !void {
        self.addMirror(old_buf) catch unreachable;

        // initial copy

        const src = old_buf;
        const dst = self.base.buffer;

        std.debug.assert(src.mode.height == dst.mode.height);
        std.debug.assert(src.mode.width == dst.mode.width);

        var dst_offset: usize = 0;
        var src_offset: usize = 0;

        const end = src.bytes * src.mode.width;

        for (0..src.mode.height) |_| {
            @memcpy(
                dst.buf[dst_offset .. dst_offset + end],
                src.buf[src_offset .. src_offset + end],
            );

            dst_offset += dst.mode.pitch;
            src_offset += src.mode.pitch;
        }
    }

    pub inline fn addMirror(self: *Self, buffer: Framebuffer) !void {
        try self.mirrors.append(memory.allocator, buffer);
    }

    // SPECIAL CHARACTER HANDLING

    pub inline fn put(self: *Self, char: u8) void {
        self.base.put(char);
    }

    pub inline fn print(self: *Self, string: []const u8) void {
        for (string) |c| self.put(c);
    }

    // SCROLLING / CLEARING

    pub inline fn clear(self: *Self) void {
        self.base.clear();
        if (self.mirrors.items.len > 0) self.damage = .{
            .min = .{ 0, 0 },
            .max = .{
                self.base.info.cols * 16 * self.base.buffer.bytes,
                self.base.info.rows * 8,
            },
        };
    }
};
