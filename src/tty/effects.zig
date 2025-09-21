const std = @import("std");

const colors = @import("colors.zig");
const Color = colors.Color;
const Basic = colors.Basic;

// COLORS

pub const ColorPart = enum(u8) { foreground = 38, background = 48, underline = 58 };

// EFFECTS

pub const Effect = enum(u8) {
    bold = 1,
    faint = 2,
    // can also be set to double with 21 (ECMA-48)
    // add special case for that
    underline = 4,
    blinking = 5,
    inverse = 7,
    hidden = 8,
    strikethru = 9,
    overline = 53,

    pub const Set = std.EnumSet(Effect);

    pub inline fn unsetCode(self: Effect) u8 {
        return switch (self) {
            // many consoles have this as 21 but ECMA-28 says otherwise
            // newer Linux kernels follow ECMA-28, let's copy that behavior
            .bold => 22,
            .overline => 55,
            else => @intFromEnum(self) + 20,
        };
    }
};

pub const StatefulEffect = union(Effect) {
    bold,
    faint,
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

    pub fn format(self: StatefulEffect, writer: *std.Io.Writer) !void {
        if (self == .underline) {
            try writer.print("4:{}", .{@intFromEnum(self.underline)});
        } else try writer.print("{}", .{@intFromEnum(@as(Effect, self))});
    }
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

    pub fn set(self: *Effects, comptime effect: Effect, value: effectType(effect)) void {
        if (effect == .underline) {
            if (value) |underline| {
                self.inner.insert(.underline);
                self.underline = underline;
            } else self.inner.remove(.underline);
            return;
        }

        if (value) self.inner.insert(effect) else self.inner.remove(effect);
    }

    pub fn get(self: Effects, comptime effect: Effect) effectType(effect) {
        const contains = self.inner.contains(effect);
        return switch (effect) {
            .underline => if (contains) self.underline else null,
            else => contains,
        };
    }
};

// ANSI ESCAPE CODES

const memory = @import("../memory.zig");
const allocator = memory.allocator;

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
    multi_sgr: std.ArrayList(Sgr),
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
        set_effect: StatefulEffect,
        unset_effect: Effect,
        set_color: struct {
            part: ColorPart,
            color: ?Color = null,
        },

        pub fn format(self: Sgr, writer: *std.Io.Writer) !void {
            return switch (self) {
                .reset => {},
                .set_effect => |v| writer.print("{f}", .{v}),
                .unset_effect => |v| writer.print("{}", .{v.unsetCode()}),
                .set_color => |v| writeSetColor(writer, v.part, v.color),
            };
        }

        inline fn writeSetColor(writer: *std.Io.Writer, part: ColorPart, color: ?Color) !void {
            // set to default color. combined into one command for simplicity sake
            if (color == null) return writer.print("{}", .{@intFromEnum(part) + 1});

            color: switch (color.?) {
                .basic => |v| {
                    // underline doesn't have the basic color settings. use the 256-color one
                    if (part == .underline) continue :color .{ .@"256" = @intFromEnum(v) };
                    try writer.print("{}", .{v.toAnsi(part == .background)});
                },
                .@"256" => |v| try writer.print("{};5;{}", .{ @intFromEnum(part), v }),
                .rgb => |v| {
                    const rgb = v.toBpc8();
                    const params = .{ @intFromEnum(part), rgb.r, rgb.g, rgb.b };
                    return writer.print("{};2;{};{};{}", params);
                },
            }
        }

        pub fn parse(buffer: []const u8) ?std.ArrayList(Sgr) {
            var iterator = std.mem.SplitIterator(u8, .scalar){
                .buffer = buffer,
                .delimiter = ';',
                .index = 0,
            };
            var out = std.ArrayList(Sgr){};

            while (iterator.next()) |part| {
                switch (std.fmt.parseInt(u8, part, 10) catch continue) {
                    0 => out.append(allocator, .reset) catch return null,
                    1 => out.append(allocator, .{ .set_effect = .bold }) catch return null,
                    2 => out.append(allocator, .{ .set_effect = .faint }) catch return null,
                    // we don't support italics so we'll just do blinking instead
                    3 => out.append(allocator, .{ .set_effect = .blinking }) catch return null,
                    // TODO: underline
                    4 => continue,
                    5 => out.append(allocator, .{ .set_effect = .blinking }) catch return null,
                    // TODO: rapid blink
                    6 => continue,
                    7 => out.append(allocator, .{ .set_effect = .inverse }) catch return null,
                    8 => out.append(allocator, .{ .set_effect = .hidden }) catch return null,
                    9 => out.append(allocator, .{ .set_effect = .strikethru }) catch return null,
                    // font changing not supported
                    10...19 => continue,
                    // fraktur not supported
                    20 => continue,
                    // double-underline per ECMA-48, on some consoles disables bold though
                    21 => out.append(allocator, .{ .set_effect = .{ .underline = .double } }) catch return null,
                    22 => {
                        // normal intensity; unsets both bold and faint
                        out.append(allocator, .{ .unset_effect = .bold }) catch return null;
                        out.append(allocator, .{ .unset_effect = .faint }) catch return null;
                    },
                    // we don't support italics so we'll just do blinking instead
                    23 => out.append(allocator, .{ .unset_effect = .blinking }) catch return null,
                    24 => out.append(allocator, .{ .unset_effect = .underline }) catch return null,
                    25 => out.append(allocator, .{ .unset_effect = .blinking }) catch return null,
                    // TODO: rapid blink
                    26 => continue,
                    27 => out.append(allocator, .{ .unset_effect = .inverse }) catch return null,
                    28 => out.append(allocator, .{ .unset_effect = .hidden }) catch return null,
                    29 => out.append(allocator, .{ .unset_effect = .strikethru }) catch return null,
                    30...37 => |v| out.append(
                        allocator,
                        .{ .set_color = .{
                            .part = .foreground,
                            .color = .{ .basic = @enumFromInt(v - 30) },
                        } },
                    ) catch return null,
                    // TODO: advanced foreground color setting
                    38 => continue,
                    39 => out.append(allocator, .{ .set_color = .{ .part = .foreground } }) catch return null,
                    40...47 => |v| out.append(
                        allocator,
                        .{ .set_color = .{
                            .part = .background,
                            .color = .{ .basic = @enumFromInt(v - 40) },
                        } },
                    ) catch return null,
                    // TODO: advanced background color setting
                    48 => continue,
                    49 => out.append(allocator, .{ .set_color = .{ .part = .background } }) catch return null,
                    53 => out.append(allocator, .{ .set_effect = .overline }) catch return null,
                    55 => out.append(allocator, .{ .unset_effect = .overline }) catch return null,
                    // TODO: underline color setting
                    58 => continue,
                    59 => out.append(allocator, .{ .set_color = .{ .part = .underline } }) catch return null,
                    90...97 => |v| out.append(
                        allocator,
                        .{ .set_color = .{
                            .part = .foreground,
                            .color = .{ .basic = @enumFromInt((v - 90) + 8) },
                        } },
                    ) catch return null,
                    100...107 => |v| out.append(
                        allocator,
                        .{ .set_color = .{
                            .part = .background,
                            .color = .{ .basic = @enumFromInt((v - 100) + 8) },
                        } },
                    ) catch return null,

                    // invalid command
                    else => continue,
                }
            }

            return out;
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
            .multi_sgr => |v| {
                if (v.items.len > 0) {
                    try writer.print("{f}", .{v.items[0]});
                    for (v.items[1..]) |sgr| {
                        try writer.print(";{f}", .{sgr});
                    }
                }
                try writer.writeByte('m');
            },
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
                self.buffer.ensureTotalCapacity(allocator, 32) catch unreachable;
                self.parsing = true;
                return true;
            } else return false;
        }

        if (self.nop or !memory.ready) {
            switch (char) {
                // Control Sequence Introducer
                '[' => self.csi = true,
                // CSI COMMANDS
                'A', 'B', 'C', 'D', 'E', 'F', 'f', 'G', 'H', 'h', 'i', 'J', 'K', 'l', 'm', 'n', 'S', 's', 'T', 'u' => self.parsing = false,
                // NON-CSI COMMANDS
                '7', '8' => if (!self.csi) {
                    self.parsing = false;
                },
                'M' => self.parsing = false,
                else => {},
            }
            return true;
        }

        var do_reset = true;
        self.parsed = parser: switch (char) {
            // Control Sequence Introducer
            '[' => {
                if (self.buffer.items.len > 0) break :parser null;
                do_reset = false;
                self.csi = true;
                break :parser null;
            },

            // CSI COMMANDS

            // single number movement commands
            'A', 'B', 'C', 'D', 'E', 'F', 'G', 'S', 'T' => |c| if (self.csi) {
                var movement = Command.Movement{};
                movement.distance = std.fmt.parseInt(usize, self.buffer.items, 10) catch break :parser null;
                movement.forward = switch (c) {
                    'B', 'C', 'E', 'T' => true,
                    else => false,
                };
                break :parser switch (c) {
                    'A', 'B' => .{ .move_v = movement },
                    'C', 'D' => .{ .move_h = movement },
                    'E', 'F' => .{ .move_line = movement },
                    'G' => .{ .move_column = movement.distance },
                    'S', 'T' => .{ .scroll = movement },
                    else => unreachable,
                };
            } else null,
            // move cursor absolute
            'H', 'f' => if (self.csi) {
                var cmd = Command{ .move_absolute = .{} };
                const len = self.buffer.items.len;
                if (len == 0) break :parser null;
                // only column is set
                if (self.buffer.items[0] == ';') {
                    cmd.move_absolute.col = std.fmt.parseInt(usize, self.buffer.items[1..], 10) catch break :parser null;
                    break :parser cmd;
                }
                var i: usize = 0;
                while (i < len and self.buffer.items[i] != ';') i += 1;
                cmd.move_absolute.row = std.fmt.parseInt(usize, self.buffer.items[0..i], 10) catch break :parser null;
                // only row is set
                if (i >= len - 1) break :parser null;
                // both row and column set
                cmd.move_absolute.col = std.fmt.parseInt(usize, self.buffer.items[i + 1 ..], 10) catch break :parser null;
                break :parser cmd;
            } else null,
            // erase commands
            'J', 'K' => |c| if (self.csi) {
                var value: u2 = 0;
                if (self.buffer.items.len > 0)
                    value = std.fmt.parseInt(u2, self.buffer.items, 10) catch break :parser null;
                // u2 holds up to 3, but Erase in Line is from 0-2
                if (c == 'K' and value == 3) break :parser null;
                break :parser switch (c) {
                    'J' => .{ .erase_display = value },
                    'K' => .{ .erase_line = value },
                    else => unreachable,
                };
            } else null,
            // select graphic rendition
            'm' => if (self.csi) {
                // CSI m is an alias of CSI 0 m, which is the reset command
                if (self.buffer.items.len == 0) break :parser .{ .sgr = .reset };
                const sgr = Command.Sgr.parse(self.buffer.items) orelse break :parser null;
                break :parser .{ .multi_sgr = sgr };
            } else null,
            // report cursor position
            'n' => if (self.csi) {
                if (self.buffer.items.len != 0 or
                    self.buffer.items[0] != '6')
                    break :parser null;
                break :parser .report_cursor;
            } else null,
            // save/restore cursor position (SCO)
            's', 'u' => |c| if (self.csi) {
                if (self.buffer.items.len > 0) break :parser null;
                break :parser .{ .cursor_pos_store = .{ .restore = c == 'u' } };
            } else null,
            // show/hide cursor
            'h', 'l' => |c| if (self.csi) {
                const len = self.buffer.items.len;
                if (len < 2 or
                    self.buffer.items[len - 2] != '2' or
                    self.buffer.items[len - 1] != '5')
                    break :parser null;
                break :parser .{ .cursor_visible = c == 'h' };
            } else null,

            // NON-CSI COMMANDS

            // move cursor up one line, scroll if needed
            'M' => if (!self.csi) {
                if (self.buffer.items.len > 0) break :parser null;
                // default distance is 1, default direction is up
                break :parser .{ .move_v = .{ .can_scroll = true } };
            } else null,
            // save/restore cursor position (DEC)
            '7', '8' => |c| if (!self.csi) {
                if (self.buffer.items.len > 0) break :parser null;
                break :parser .{ .cursor_pos_store = .{ .dec = true, .restore = c == '8' } };
            } else {
                // numbers could be part of a CSI command
                // TODO: we need to do something on overflow
                self.buffer.append(allocator, char) catch unreachable;
                do_reset = false;
                break :parser null;
            },

            // TODO: we need to do something on overflow
            else => {
                self.buffer.append(allocator, char) catch unreachable;
                do_reset = false;
                break :parser null;
            },
        };

        if (do_reset) self.reset();
        return true;
    }

    inline fn reset(self: *Self) void {
        self.buffer.shrinkAndFree(allocator, 32);
        self.buffer.clearRetainingCapacity();
        self.parsing = false;
        self.csi = false;
    }
};
