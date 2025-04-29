const io = @import("io.zig");
const int = @import("int.zig");

// PROGRAMMABLE INTERVAL TIMER
// https://wiki.osdev.org/Programmable_Interval_Timer

pub const pit_max_divisor = 29102; // largest factor of 1193182 thats <= 65535
pub const pit_min_hz = 1193182 / pit_max_divisor; // divisor is factor, will be int

pub inline fn hzToPITDivisor(hz: f64) u16 {
    const div = 1193182.0 / hz;
    return @intFromFloat(@round(div));
}

pub inline fn setPITDivisor(divisor: u16) void {
    io.out(u8, 0x43, 0b00110100);
    io.out(u8, 0x40, @truncate(divisor));
    io.out(u8, 0x40, @truncate(divisor >> 8));
}
