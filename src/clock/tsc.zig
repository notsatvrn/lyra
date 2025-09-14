//! https://wiki.osdev.org/TSC

const std = @import("std");
const util = @import("../util.zig");
const int = @import("../int.zig");
const io = @import("../io.zig");

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

fn pitTimerReading() usize {
    const int_goal = 8;

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

    return (end - start) / int_goal;
}

const cycle_goal = 0.005; // consistency goal of 0.5%

pub inline fn counterSpeed() u64 {
    pit.setDivisor(pit.max_divisor);

    int.registerIRQ(0, pitHandler, false);

    // reread until the difference is tiny
    var cycles = pitTimerReading();
    while (true) {
        const second = pitTimerReading();

        const avg = @divFloor(cycles + second, 2);
        const first_i: isize = @intCast(cycles);
        const second_i: isize = @intCast(second);
        const diff = @abs(first_i - second_i);

        const avg_f: f64 = @floatFromInt(avg);
        const diff_f: f64 = @floatFromInt(diff);
        if (diff_f / avg_f < cycle_goal) {
            // difference reached our goal
            // use the average of the results
            cycles = avg;
            break;
        } else cycles = second;
    }

    int.registerIRQ(0, null, false);

    return cycles * pit.min_hz;
}
