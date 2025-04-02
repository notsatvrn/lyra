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
    util.disableInterrupts();
    gdt.init();
    int.idt.init();
    int.remapPIC(32, 40);
}

// FURTHER SETUP WITH LOGGING

pub inline fn setup() void {
    logger.info("identify processor", .{});
    cpuid.identify();
    logger.info("- vendor: {s}", .{@tagName(cpuid.vendor)});
    if (!cpuid.features.invariant_tsc)
        log.panic(null, "Invariant TSC unavailable!", .{});
}
