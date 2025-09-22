//! https://wiki.osdev.org/TSC

const std = @import("std");
const util = @import("../util.zig");
const int = @import("../int.zig");

pub inline fn counter() u64 {
    var lo: u32 = 0;
    var hi: u32 = 0;

    asm volatile (
        \\rdtsc
        : [lo] "={eax}" (lo),
          [hi] "={edx}" (hi),
    );

    return (@as(u64, hi) << 32) | @as(u64, lo);
}

// Using the PIT to estimate CPU speed for a time stamp counter clock.
// Based on https://wiki.osdev.org/Detecting_CPU_Speed#Working_Example_Code

const pit = @import("pit.zig");

var last_reading: usize = 0;
var pit_ints: usize = 0;

inline fn pitHandler(_: *int.InterruptStack) void {
    last_reading = counter();
    pit_ints += 1;
}

const logger = @import("../log.zig").Logger{ .name = "bruh" };

const int_goal = 8; // wait until 8 interrupts before reading

pub fn counterSpeed() u64 {
    util.enableInterrupts();
    int.registerIRQ(0, pitHandler);
    pit.setDivisor(pit.max_divisor);

    // first reading - short
    const first = pit_ints;
    while (pit_ints == first)
        std.atomic.spinLoopHint();
    const start = last_reading;

    // second reading - long
    const goal = pit_ints + int_goal;
    var tmp: usize = 0;
    while (pit_ints < goal) {
        tmp += 1;
        std.mem.doNotOptimizeAway(tmp);
    }
    const end = last_reading;

    int.registerIRQ(0, null);
    util.disableInterrupts();

    const cycles = (end - start) / int_goal;
    return cycles * pit.min_hz;
}
