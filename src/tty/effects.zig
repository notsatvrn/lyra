const std = @import("std");

const colors = @import("colors.zig");
const Color = colors.Color;

// COLORS

pub const ColorPart = enum(u8) { foreground = 38, background = 48, underline = 58 };

pub inline fn writeColorSGR(color: Color, writer: anytype, part: ColorPart) !void {
    return print: switch (color) {
        .basic => |v| writer.print("{d};5;{d}", .{ @intFromEnum(part), @intFromEnum(v) }),
        .@"256" => |v| writer.print("{d};5;{d}", .{ @intFromEnum(part), v }),
        .hsl => |v| continue :print .{ .rgb = colors.RGB.fromHSL(v) },
        .rgb => |v| {
            const rgb24 = v.getSize(.bpp24);
            const params = .{@intFromEnum(part)} ++ rgb24;
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

// includes effect states
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

pub const ANSI = union(enum) {
    sgr: SGR,

    // Set Graphics Rendition

    pub const SGR = union(enum) {
        reset,
        set_color: struct { part: ColorPart, color: Color },
        set_effect: StatefulEffect,
        unset_effect: Effect,

        pub fn format(
            self: SGR,
            comptime fmt: []const u8,
            options: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            _ = fmt;
            _ = options;

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

    pub fn format(
        self: ANSI,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        if (true) return;

        try writer.writeByte(esc);
        switch (self) {
            .sgr => |v| try writer.print("[{s}m", .{v}),
        }
    }

    // quick constructors

    pub const reset = ANSI{ .sgr = .reset };

    pub inline fn setColor(part: ColorPart, color: Color) ANSI {
        return .{ .sgr = .{ .set_color = .{ .part = part, .color = color } } };
    }
};
