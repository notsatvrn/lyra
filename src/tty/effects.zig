const std = @import("std");

const colors = @import("colors.zig");
const Color = colors.Color;

// COLORS

pub const ColorPart = enum(u8) { foreground = 38, background = 48, underline = 58 };

inline fn writeColorSGR(color: Color, writer: *std.Io.Writer, part: ColorPart) !void {
    return print: switch (color) {
        .basic => |v| continue :print .{ .@"256" = @intFromEnum(v) },
        .@"256" => |v| writer.print("{d};5;{d}", .{ @intFromEnum(part), v }),
        .rgb => |v| {
            const rgb24 = v.getSize(.bpp24);
            const params = .{ @intFromEnum(part), rgb24.r, rgb24.g, rgb24.b };
            return writer.print("{d};2;{d};{d};{d}", params);
        },
    };
}

// EFFECTS

pub const Effect = enum(u8) {
    bold = 1,
    // this one is a bit weirdly handled in RenderState
    // mode is changed in Palettes struct instead of checking each time
    dim = 2,
    italic = 3,
    // can also be set to double with 21 (ECMA-48)
    // add special case for that
    underline = 4,
    blinking = 5,
    inverse = 7,
    hidden = 8,
    strikethru = 9,
    overline = 53,

    pub const Set = std.EnumSet(Effect);

    pub inline fn setCode(self: Effect) u8 {
        return @intFromEnum(self);
    }

    pub inline fn unsetCode(self: Effect) u8 {
        return switch (self) {
            // many consoles have this as 21 but ECMA-28 says otherwise
            // newer Linux kernels follow ECMA-28, let's copy that behavior
            .bold => 22,
            .overline => 55,
            else => self.setCode() + 20,
        };
    }
};

pub const StatefulEffect = union(Effect) {
    bold,
    dim,
    italic,
    underline: Underline,
    blinking,
    inverse,
    hidden,
    strikethru,
    overline,

    pub const Underline = enum(u3) {
        single = 1,
        double = 2,
        curly = 3,
        dotted = 4,
        dashed = 5,
    };
};

pub const Effects = struct {
    inner: Effect.Set = Effect.Set.initEmpty(),
    underline: StatefulEffect.Underline = .single,

    // std.meta.FieldType doesn't work here
    fn effectType(comptime effect: Effect) type {
        const state_info = @typeInfo(StatefulEffect).@"union";
        var typ: type = void;
        for (state_info.fields) |field| {
            if (std.mem.eql(u8, field.name, @tagName(effect)))
                typ = field.type;
        }

        return if (typ == void) bool else @Type(.{ .optional = .{ .child = typ } });
    }

    pub inline fn set(self: *Effects, comptime effect: Effect, value: bool) void {
        if (effect == .underline) @compileError("use Effects.setUnderline");
        if (value) self.inner.insert(effect) else self.inner.remove(effect);
    }

    pub inline fn setUnderline(self: *Effects, u: ?StatefulEffect.Underline) void {
        if (u) |ul| {
            self.inner.insert(.underline);
            self.underline = ul;
        } else self.inner.remove(.underline);
    }

    pub inline fn get(self: Effects, comptime effect: Effect) effectType(effect) {
        const contains = self.inner.contains(effect);
        return switch (effect) {
            .underline => if (contains) self.underline else null,
            else => contains,
        };
    }
};

// ANSI ESCAPE CODES

const memory = @import("../memory.zig");

pub const Ansi = union(enum) {
    sgr: Sgr,

    // Set Graphics Rendition

    pub const Sgr = union(enum) {
        reset,
        set_color: struct { part: ColorPart, color: Color },
        set_effect: StatefulEffect,
        unset_effect: Effect,

        pub fn format(self: Sgr, writer: *std.Io.Writer) !void {
            switch (self) {
                .reset => try writer.writeByte('0'),
                .set_color => |v| try writeColorSGR(v.color, writer, v.part),
                .set_effect => |v| try writer.print("{}", .{@as(Effect, v).setCode()}),
                .unset_effect => |v| try writer.print("{}", .{v.unsetCode()}),
            }
        }
    };

    // rest of the implementation

    pub const esc = '\x1B';

    pub fn format(self: Ansi, writer: *std.Io.Writer) !void {
        if (!memory.ready) return;

        try writer.writeByte(esc);
        switch (self) {
            .sgr => |v| try writer.print("[{f}m", .{v}),
        }
    }

    // quick constructors

    pub const reset = Ansi{ .sgr = .reset };

    pub inline fn setColor(part: ColorPart, color: Color) Ansi {
        return .{ .sgr = .{ .set_color = .{ .part = part, .color = color } } };
    }
};

// ANSI ESCAPE CODE PARSER

// The ANSI escape parser used by all TTY implementations
pub const AnsiParser = struct {
    parsing: ?Parsing = null,
    nop: bool = false,

    const Self = @This();

    const Parsing = struct {
        buffer: std.ArrayList(u8),
    };

    pub fn checkChar(self: *Self, char: u8) bool {
        if (self.parsing) |*p| {
            _ = p;
            // TODO: for now it's always a nop, but we need a parser
            if (self.nop or true) {
                switch (char) {
                    'A', 'B', 'C', 'D', 'E', 'F', 'f', 'G', 'H', 'h', 'i', 'J', 'K', 'l', 'm', 'n', 'S', 's', 'T', 'u' => self.parsing = null,
                    else => {},
                }
            }
        } else if (char == Ansi.esc) {
            self.parsing = .{
                .buffer = std.ArrayList(u8).initCapacity(memory.allocator, 16) catch return true,
            };
        } else return false;

        return true;
    }
};
