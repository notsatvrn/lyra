const std = @import("std");

const limine = @import("../../limine.zig");

const gdt = @import("gdt.zig");
const int = @import("int.zig");
const util = @import("util.zig");
const cpuid = @import("cpuid.zig");
const time = @import("time.zig");

const log = @import("../../log.zig");
const logger = log.Logger{ .name = "x86-64/boot" };

// INITIAL SETUP

pub inline fn init() void {
    time.tsc_init = time.rdtsc();
    util.disableInterrupts();
}

// FURTHER SETUP WITH LOGGING

pub inline fn setup() void {
    logger.info("init global descriptor table", .{});
    gdt.init();

    logger.info("init interrupt descriptor table", .{});
    int.idt.init();

    logger.info("run cpuid", .{});
    cpuid.identify();

    logger.info("remap pic", .{});
    int.remapPIC(32, 40);
    logger.info("setup timing", .{});
    time.setupTimingFast();
    logger.info("setup clock", .{});
    time.setupClock(time.readRTC());
}
