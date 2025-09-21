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
            const rgb = v.toBpc8();
            const params = .{ @intFromEnum(part), rgb.r, rgb.g, rgb.b };
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

pub const Command = union(enum) {
    move_v: Movement,
    move_h: Movement,
    move_line: Movement,
    move_column: usize,
    move_absolute: struct {
        row: usize = 1,
        col: usize = 1,
    },
    erase_display: u2,
    erase_line: u2,
    scroll: Movement,
    sgr: Sgr,
    report_cursor,
    cursor_pos_store: CursorPosStore,
    // true to show it
    cursor_visible: bool,

    // movement commands

    pub const Movement = struct {
        distance: usize = 1,
        // for vertical, down is true
        forward: bool = false,
        can_scroll: bool = false,
    };

    // cursor position storage commands

    pub const CursorPosStore = struct {
        restore: bool,
        // if false, use SCO format
        dec: bool = false,

        pub fn char(self: CursorPosStore) u8 {
            if (self.dec) return if (self.restore) '8' else '7';
            return if (self.restore) 'u' else 's';
        }
    };

    // Select Graphic Rendition

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

        pub fn parse(buffer: []const u8) ?Sgr {
            _ = buffer;
            return null;
        }
    };

    // rest of the implementation

    pub const esc = '\x1B';

    pub fn format(self: Command, writer: *std.Io.Writer) !void {
        if (!memory.ready) return;

        try writer.writeByte(esc);
        // Control Sequence Introducer -
        // cursor pos store w/ DEC format
        // does not have the CSI character
        if (self != .cursor_pos_store or
            !self.cursor_pos_store.dec)
            try writer.writeByte('[');

        try switch (self) {
            .move_v => |v| writer.print("{}{c}", .{ v.distance, @as(u8, if (v.forward) 'B' else 'A') }),
            .move_h => |v| writer.print("{}{c}", .{ v.distance, @as(u8, if (v.forward) 'C' else 'D') }),
            .move_line => |v| writer.print("{}{c}", .{ v.distance, @as(u8, if (v.forward) 'E' else 'F') }),
            .move_column => |v| writer.print("{}G", .{v}),
            .move_absolute => |v| writer.print("{};{}H", .{ v.row, v.col }),
            .erase_display => |v| writer.print("{}J", .{v}),
            .erase_line => |v| writer.print("{}K", .{v}),
            .scroll => |v| writer.print("{}{c}", .{ v.distance, @as(u8, if (v.forward) 'T' else 'S') }),
            .sgr => |v| writer.print("{f}m", .{v}),
            .report_cursor => writer.writeAll("6n"),
            .cursor_pos_store => |v| writer.writeByte(v.char()),
            .cursor_visible => |v| writer.print("25{c}", .{@as(u8, if (v) 'h' else 'l')}),
        };
    }

    // quick constructors

    pub const reset = Command{ .sgr = .reset };

    pub inline fn setColor(part: ColorPart, color: Color) Command {
        return .{ .sgr = .{ .set_color = .{ .part = part, .color = color } } };
    }
};

// https://en.wikipedia.org/wiki/ANSI_escape_code
// https://gist.github.com/fnky/458719343aabd01cfb17a3a4f7296797
pub const Parser = struct {
    nop: bool = false,
    parsing: bool = false,
    csi: bool = false,
    buffer: std.ArrayList(u8) = .{},
    parsed: ?Command = null,

    const Self = @This();

    pub fn parse(self: *Self, char: u8) bool {
        if (!self.parsing) {
            @branchHint(.likely);
            if (char == Command.esc) {
                self.buffer.ensureTotalCapacity(memory.allocator, 32) catch unreachable;
                self.buffer.clearRetainingCapacity();
                self.parsing = true;
                return true;
            } else return false;
        }

        if (self.nop or !memory.ready) {
            switch (char) {
                'A', 'B', 'C', 'D', 'E', 'F', 'f', 'G', 'H', 'h', 'i', 'J', 'K', 'l', 'm', 'n', 'S', 's', 'T', 'u' => self.parsing = false,
                else => {},
            }
            return true;
        }

        parser: switch (char) {
            // Control Sequence Introducer
            '[' => {
                if (self.buffer.items.len != 0) {
                    self.reset();
                    return true;
                }
                self.csi = true;
            },

            // CSI COMMANDS

            // single number movement commands
            'A', 'B', 'C', 'D', 'E', 'F', 'G', 'S', 'T' => |c| if (!self.csi) self.reset() else {
                var movement = Command.Movement{};
                movement.distance = std.fmt.parseInt(usize, self.buffer.items, 10) catch {
                    self.reset();
                    return true;
                };
                movement.forward = switch (c) {
                    'B', 'C', 'E', 'T' => true,
                    else => false,
                };
                self.parsed = switch (c) {
                    'A', 'B' => .{ .move_v = movement },
                    'C', 'D' => .{ .move_h = movement },
                    'E', 'F' => .{ .move_line = movement },
                    'G' => .{ .move_column = movement.distance },
                    'S', 'T' => .{ .scroll = movement },
                    else => unreachable,
                };
                self.reset();
            },
            // move cursor absolute
            'H', 'f' => if (!self.csi) self.reset() else {
                self.parsed = .{ .move_absolute = .{} };
                const len = self.buffer.items.len;
                if (len == 0) {
                    self.reset();
                    return true;
                }
                // only column is set
                if (self.buffer.items[0] == ';') {
                    self.parsed.?.move_absolute.col =
                        std.fmt.parseInt(usize, self.buffer.items[1..], 10) catch {
                            self.parsed = null;
                            break :parser self.reset();
                        };
                    self.reset();
                    return true;
                }
                var i: usize = 0;
                while (i < len and self.buffer.items[i] != ';') i += 1;
                self.parsed.?.move_absolute.row =
                    std.fmt.parseInt(usize, self.buffer.items[0..i], 10) catch {
                        self.parsed = null;
                        break :parser self.reset();
                    };
                // only row is set
                if (i == len) {
                    self.reset();
                    return true;
                }
                // both row and column set
                self.parsed.?.move_absolute.col =
                    std.fmt.parseInt(usize, self.buffer.items[i + 1 ..], 10) catch {
                        self.parsed = null;
                        self.reset();
                        return true;
                    };
                self.reset();
            },
            // erase commands
            'J', 'K' => |c| if (!self.csi) self.reset() else {
                var value: u2 = 0;
                if (self.buffer.items.len > 0)
                    value = std.fmt.parseInt(u2, self.buffer.items, 10) catch {
                        self.reset();
                        return true;
                    };
                // u2 holds up to 3, but Erase in Line is from 0-2
                if (c == 'K' and value == 3) {
                    self.reset();
                    return true;
                }
                self.parsed = switch (c) {
                    'J' => .{ .erase_display = value },
                    'K' => .{ .erase_line = value },
                    else => unreachable,
                };
                self.reset();
            },
            // select graphic rendition
            'm' => if (!self.csi) self.reset() else {
                const sgr = Command.Sgr.parse(self.buffer.items) orelse {
                    self.reset();
                    return true;
                };
                self.parsed = .{ .sgr = sgr };
            },
            // report cursor position
            'n' => if (!self.csi) self.reset() else {
                if (self.buffer.items.len != 0 or
                    self.buffer.items[0] != '6')
                {
                    self.reset();
                    return true;
                }
                self.parsed = .report_cursor;
            },
            // save/restore cursor position (SCO)
            's', 'u' => |c| if (!self.csi) self.reset() else {
                if (self.buffer.items.len > 0) {
                    self.reset();
                    return true;
                }
                self.parsed = .{ .cursor_pos_store = .{ .restore = c == 'u' } };
            },
            // show/hide cursor
            'h', 'l' => |c| if (!self.csi) self.reset() else {
                const len = self.buffer.items.len;
                if (len < 2 or
                    self.buffer.items[len - 2] != '2' or
                    self.buffer.items[len - 1] != '5')
                {
                    self.reset();
                    return true;
                }
                self.parsed = .{ .cursor_visible = c == 'h' };
                self.reset();
            },

            // NON-CSI COMMANDS

            // move cursor up one line, scroll if needed
            'M' => if (self.csi) self.reset() else {
                if (self.buffer.items.len != 0) {
                    self.reset();
                    return true;
                }
                // default distance is 1, default direction is up
                self.parsed = .{ .move_v = .{ .can_scroll = true } };
            },
            // save/restore cursor position (DEC)
            '7', '8' => |c| if (self.csi) self.reset() else {
                if (self.buffer.items.len > 0) {
                    self.reset();
                    return true;
                }
                self.parsed = .{ .cursor_pos_store = .{ .dec = true, .restore = c == '8' } };
            },

            // TODO: we need to do something on overflow
            else => self.buffer.append(memory.allocator, char) catch unreachable,
        }

        return true;
    }

    inline fn reset(self: *Self) void {
        self.buffer.clearRetainingCapacity();
        self.parsing = false;
        self.csi = false;
    }
};
