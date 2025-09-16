const std = @import("std");
const tsc = @import("clock/tsc.zig");
const rtc = @import("clock/rtc.zig");

const logger = @import("log.zig").Logger{ .name = "clock" };

// COUNTER-BASED CLOCK
// https://wiki.osdev.org/TSC
// https://wiki.osdev.org/HPET (fallback in the future)

pub var init: u64 = 0;
pub var speed: u64 = 0; // in hertz

pub fn setup() void {
    speed = tsc.counterSpeed();
    logger.info("counter speed: {}MHz", .{speed / std.time.ns_per_ms});
    init = tsc.counter();
    // counts per microsecond for stall power consumption hack
    us_counts = countsPerNanos(std.time.ns_per_us);
    setupClock(rtc.read());
    logger.info("timestamp: {}", .{timestamp()});
}

inline fn nanoSinceCount(count: u64) u64 {
    const count_diff = @as(u128, tsc.counter() - count) * std.time.ns_per_s;
    return @truncate(count_diff / @as(u128, speed));
}

// get nanoseconds since we first read counter
pub fn nanoSinceBoot() u64 {
    if (speed == 0) return 0;
    return nanoSinceCount(init);
}

// REAL TIME CLOCK (RTC)

// initial system clock reading + counter avoids slow/inaccurate RTC reads
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
        .count_init = tsc.counter(),
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
    const start = tsc.counter();
    const goal = start + countsPerNanos(n);

    // improve power consumption on longer stalls
    // loop hint puts the CPU to sleep for a bit
    // should be accurate to about a microsec
    if (n > std.time.ns_per_us) {
        const ugoal = goal - us_counts;
        while (ugoal > tsc.counter())
            std.atomic.spinLoopHint();
    }

    while (goal > tsc.counter()) {}
}
