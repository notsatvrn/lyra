//! https://wiki.osdev.org/Programmable_Interval_Timer

const util = @import("../util.zig");

pub const max_divisor = 29102; // largest factor of 1193182 thats <= 65535
pub const min_hz = 1193182 / max_divisor; // divisor is factor, will be int

pub inline fn hzToDivisor(hz: f64) u16 {
    const div = 1193182.0 / hz;
    return @intFromFloat(@round(div));
}

pub inline fn setDivisor(divisor: u16) void {
    util.out(u8, 0x43, 0b00110100);
    util.out(u8, 0x40, @truncate(divisor));
    util.out(u8, 0x40, @truncate(divisor >> 8));
}

pub inline fn disable() void {
    util.out(u8, 0x40, 0b00110000);
    util.out(u8, 0x40, 0);
    util.out(u8, 0x40, 0);
}
