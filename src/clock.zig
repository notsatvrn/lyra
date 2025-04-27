const std = @import("std");
const arch = @import("arch.zig").clock;

const log = @import("log.zig");
const logger = log.Logger{ .name = "clock" };

// COUNTER-BASED CLOCK
// https://wiki.osdev.org/TSC - x86-64
// https://wiki.osdev.org/ARMv7_Generic_Timers - aarch64

pub var init: u64 = 0;
pub var speed: u64 = 0; // in hertz

pub inline fn setup() void {
    logger.info("calibrate counters", .{});
    speed = arch.counterSpeed();
    logger.info("counter speed: {}MHz", .{speed / std.time.ns_per_ms});
    init = arch.counter();
    // counts per microsecond for stall power consumption hack
    us_counts = countsPerNanos(std.time.ns_per_us);
    logger.info("read system clock", .{});
    setupClock(arch.readSystemClock());
    logger.info("timestamp: {}", .{timestamp()});
}

inline fn nanoSinceCount(count: u64) u64 {
    const count_diff = @as(u128, arch.counter() - count) * std.time.ns_per_s;
    return @truncate(count_diff / @as(u128, speed));
}

// get nanoseconds since we first read counter
pub fn nanoSinceBoot() u64 {
    if (speed == 0) return 0;
    return nanoSinceCount(init);
}

// SYSTEM CLOCK

// initial Real Time Clock reading + TSC avoids slow/inaccurate RTC reads
// (count_init - current count) * 1000 / CPU speed + base_init = current time
const ClockState = struct {
    base_init: u64,
    count_init: u64,
};

var clock_state: ?ClockState = null;

// change the base timestamp
// useful when we get an NTP reading
pub inline fn setupClock(base: u64) void {
    if (base != 0) clock_state = .{
        .base_init = base,
        .count_init = arch.counter(),
    };
}

// get the current unix timestamp in ns
pub fn timestamp() u64 {
    if (clock_state) |state| {
        const ns = nanoSinceCount(state.count_init);
        return (ns / std.time.ns_per_s) + state.base_init;
    } else return 0;
}

// TIMING HELPERS

inline fn countsPerNanos(n: usize) usize {
    const nanocounts = @as(u128, n) * @as(u128, speed);
    return @truncate(nanocounts / std.time.ns_per_s);
}

var us_counts: usize = 0;

// busy-wait for n nanoseconds
// ideal for smaller waits
pub fn stall(n: usize) void {
    const start = arch.counter();
    const goal = start + countsPerNanos(n);

    // improve power consumption on longer stalls
    // loop hint puts the CPU to sleep for a bit
    // should be accurate to about a microsec
    if (n > std.time.ns_per_us) {
        const ugoal = goal - us_counts;
        while (ugoal > arch.counter())
            std.atomic.spinLoopHint();
    }

    while (goal > arch.counter()) {}
}
