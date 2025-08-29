const limine = @import("../../limine.zig");

const gdt = @import("gdt.zig");
const int = @import("int.zig");
const util = @import("util.zig");
const cpuid = @import("cpuid.zig");

const logger = @import("../../log.zig").Logger{ .name = "x86-64/boot" };

// INITIAL SETUP

pub inline fn init() void {
    gdt.init();
    int.idt.init();
    int.remapPIC(32, 40);
    util.enablePICInterrupts();
}

// FURTHER SETUP WITH LOGGING

pub inline fn setup() void {
    logger.info("identify processor", .{});
    cpuid.identify();
    logger.info("- vendor is {s}", .{@tagName(cpuid.vendor)});
    if (!cpuid.features.invariant_tsc)
        logger.panic("- invariant TSC not supported!", .{});
    if (cpuid.features.x2apic)
        logger.info("- x2apic is supported", .{});
}
