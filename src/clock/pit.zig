//! https://wiki.osdev.org/Programmable_Interval_Timer

const io = @import("../io.zig");

pub const max_divisor = 29102; // largest factor of 1193182 thats <= 65535
pub const min_hz = 1193182 / max_divisor; // divisor is factor, will be int

pub inline fn hzToDivisor(hz: f64) u16 {
    const div = 1193182.0 / hz;
    return @intFromFloat(@round(div));
}

pub inline fn setDivisor(divisor: u16) void {
    io.out(u8, 0x43, 0b00110100);
    io.out(u8, 0x40, @truncate(divisor));
    io.out(u8, 0x40, @truncate(divisor >> 8));
}
