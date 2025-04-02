const std = @import("std");

const util = @import("util.zig");
const int = @import("int.zig");
const io = @import("io.zig");

const log = @import("../../log.zig");
const logger = log.Logger{ .name = "x86-64/time" };

// TIME STAMP COUNTER

pub inline fn counter() u64 {
    var lo: u32 = 0;
    var hi: u32 = 0;

    asm volatile (
        \\rdtsc
        : [lo] "={eax}" (lo),
          [hi] "={edx}" (hi),
        :
        : "eax", "edx"
    );

    return (@as(u64, hi) << 32) | @as(u64, lo);
}

// PROGRAMMABLE INTERVAL TIMER
// https://wiki.osdev.org/Programmable_Interval_Timer

var last_reading: usize = 0;
var pit_ints: usize = 0;
const pit_int_goal = 8;

inline fn pit_handler(_: *int.InterruptStack) void {
    last_reading = counter();
    pit_ints += 1;
}

fn pitTimerReading() usize {
    // first reading - short
    const pi_first = pit_ints;
    while (pit_ints == pi_first)
        std.atomic.spinLoopHint();
    const start = last_reading;

    // second reading - long
    const pi_goal = pit_ints + pit_int_goal;
    var tmp: usize = 0;
    while (pit_ints < pi_goal) {
        tmp += 1;
        std.mem.doNotOptimizeAway(tmp);
    }
    const end = last_reading;

    return (end - start) / pit_int_goal;
}

const pit_divisor = 29102; // largest factor of 1193182 thats <= 65535
const pit_hz = 1193182 / pit_divisor; // divisor is factor, will be int
const cycle_goal = 0.005; // consistency goal of 0.5%

// https://wiki.osdev.org/Detecting_CPU_Speed#Working_Example_Code
pub inline fn counterSpeed() u64 {
    // setup PIT
    io.out(u8, 0x43, 0b00110100);
    io.out(u8, 0x40, @truncate(pit_divisor));
    io.out(u8, 0x40, @truncate(pit_divisor >> 8));

    // enable interrupts
    util.enableInterrupts();
    util.enablePICInterrupts();
    // register handler
    int.registerIRQ(0, pit_handler, false);

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

    // disable interrupts
    util.disablePICInterrupts();
    util.disableInterrupts();
    // unregister handler
    int.registerIRQ(0, null, false);

    const speed = cycles * pit_hz;
    logger.debug("estimated cpu speed: {}MHz", .{speed / std.time.ns_per_ms});
    return speed;
}

// REAL TIME CLOCK

const cmos_addr = 0x70;
const cmos_data = 0x71;

const RTCOutput = packed struct(u48) {
    second: u8,
    minute: u8,
    hour: u8,
    day: u8,
    month: u8,
    year: u8,
};

// get RTC output but don't fix values
fn rawRTC() RTCOutput {
    io.out(u8, cmos_addr, 0x00);
    const sec = io.in(u8, cmos_data);
    io.out(u8, cmos_addr, 0x02);
    const min = io.in(u8, cmos_data);
    io.out(u8, cmos_addr, 0x04);
    const hr = io.in(u8, cmos_data);
    io.out(u8, cmos_addr, 0x07);
    const day = io.in(u8, cmos_data);
    io.out(u8, cmos_addr, 0x08);
    const mon = io.in(u8, cmos_data);
    io.out(u8, cmos_addr, 0x09);
    const yr = io.in(u8, cmos_data);

    return .{
        .second = sec,
        .minute = min,
        .hour = hr,
        .day = day,
        .month = mon,
        .year = yr,
    };
}

inline fn bcd2bin(bcd: u8) u8 {
    return ((bcd & 0xF0) >> 1) + ((bcd & 0xF0) >> 3) + (bcd & 0xf);
}

// fix raw RTC output
fn fixRawRTC(o: RTCOutput) RTCOutput {
    const b = io.in(u8, 0x0B);
    const bcd = (b & 0x04) == 0;
    const h24 = (b & 0x02) == 1;

    var hour = o.hour;
    if (!h24) {
        const pm = hour & 0x80 != 0;
        hour &= 0x7F;
        if (bcd) hour = bcd2bin(hour);
        if (pm) hour = (hour + 12) % 24;
    }

    if (bcd) return .{
        .second = bcd2bin(o.second),
        .minute = bcd2bin(o.minute),
        .hour = hour,
        .day = bcd2bin(o.day),
        .month = bcd2bin(o.month),
        .year = bcd2bin(o.year),
    };

    return .{
        .second = o.second,
        .minute = o.minute,
        .hour = hour,
        .day = o.day,
        .month = o.month,
        .year = o.year,
    };
}

inline fn isRTCUpdating() bool {
    io.out(u8, cmos_addr, 0x0A);
    return (io.in(u8, cmos_data) & 0x80) != 0;
}

// get RTC output safely as unix timestamp (in seconds)
pub fn readSystemClock() u64 {
    // make sure we aren't in the middle of an update

    while (isRTCUpdating()) {}
    var reading = rawRTC();

    while (true) {
        while (isRTCUpdating()) {}
        const second = rawRTC();
        if (reading != second) {
            reading = second;
        } else break;
    }

    reading = fixRawRTC(reading);

    // days from 1/1/1970 to 1/1/2000 + day of the month
    // TODO: also subtracting 1 for some reason WHY
    var days = 10957 + @as(u64, reading.day) - 1;
    const year = @as(u64, reading.year) + 2000;

    // days from past years
    for (2000..year) |y| {
        days += 365;
        if (y % 4 == 0 and (y % 100 != 0 or y % 400 == 0))
            days += 1;
    }

    // days from past months this year
    var month_days: [12]u8 = .{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    if (year % 4 == 0 and (year % 100 != 0 or year % 400 == 0)) month_days[1] = 29;
    for (0..reading.month - 1) |m| days += month_days[m];

    // convert to seconds, then return
    return days * 86400 + @as(u64, reading.hour) * 3600 + @as(u64, reading.minute) * 60 + @as(u64, reading.second);
}
