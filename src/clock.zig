const std = @import("std");
const cpuid = @import("cpuid.zig");

pub const tsc = @import("clock/tsc.zig");
pub const hpet = @import("clock/hpet.zig");
pub const rtc = @import("clock/rtc.zig");

const logger = @import("log.zig").Logger{ .name = "clock" };

// COUNTER-BASED CLOCK

pub const Source = enum {
    tsc, // https://wiki.osdev.org/TSC
    hpet, // https://wiki.osdev.org/HPET
};

pub var start: u64 = 0;
pub var speed: u64 = 0; // in hertz
pub var source: Source = undefined;

pub fn init() void {
    if (cpuid.features.invariant_tsc) {
        speed = tsc.counterSpeed();
        start = tsc.counter();
        source = .tsc;
    } else if (hpet.check()) {
        speed = hpet.counterSpeed();
        start = hpet.counter();
        source = .hpet;
    } else logger.panic("no clocksource available", .{});

    logger.info("using {s} as source", .{@tagName(source)});
    const mhz = @as(f64, @floatFromInt(speed)) / std.time.ns_per_ms;
    logger.info("counter speed: {d:.3}MHz", .{mhz});
    // counts per microsecond for stall power consumption hack
    us_counts = countsPerNanos(std.time.ns_per_us);
    setupClock(rtc.read());
    logger.info("timestamp: {}", .{timestamp()});
}

pub fn counter() usize {
    return switch (source) {
        .tsc => tsc.counter(),
        .hpet => hpet.counter(),
    };
}

inline fn nanoSinceCount(count: u64) u64 {
    const count_diff = @as(u128, counter() - count) * std.time.ns_per_s;
    return @truncate(count_diff / @as(u128, speed));
}

// get nanoseconds since we first read counter
pub fn nanoSinceBoot() u64 {
    if (speed == 0) return 0;
    return nanoSinceCount(start);
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
        .count_init = counter(),
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
    const goal = counter() + countsPerNanos(n);

    // improve power consumption on longer stalls
    // loop hint puts the CPU to sleep for a bit
    // should be accurate to about a microsec
    if (n > std.time.ns_per_us) {
        const ugoal = goal - us_counts;
        while (ugoal > counter())
            std.atomic.spinLoopHint();
    }

    while (goal > counter()) {}
}
