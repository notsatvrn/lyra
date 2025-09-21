const std = @import("std");

const limine = @import("limine.zig");
const util = @import("util.zig");
const gdt = @import("gdt.zig");
const int = @import("int.zig");
const cpuid = @import("cpuid.zig");
const memory = @import("memory.zig");
const clock = @import("clock.zig");
const acpi = @import("acpi.zig");
const smp = @import("smp.zig");
const pci = @import("pci.zig");
const rng = @import("rng.zig");

const tty = @import("tty.zig");
const gfx = @import("gfx.zig");
const log = @import("log.zig");
const logger = log.Logger{ .name = "main" };

// ENTRYPOINT

export fn stage1() noreturn {
    util.disableInterrupts();
    gdt.init();
    int.idt.init();
    int.isr.storeStack();
    int.remapPIC(32, 40);
    tty.init();
    logger.info("bootloader: {f}", .{limine.bootldr.response});
    cpuid.initVendor();
    logger.info("cpu vendor: {s}", .{@tagName(cpuid.vendor)});
    cpuid.initFeatures();
    memory.pmm.init();
    memory.vmm.init();
    tty.virtualize();
    acpi.init();
    clock.init();
    rng.initBuffers();
    pci.init();
    pci.print();
    logger.info("entering stage 2", .{});
    smp.launch(stage2);
}

fn stage2() noreturn {
    const cpu = smp.getCpu();
    memory.vmm.tables[cpu].load();
    rng.initGenerator();
    // get all the entropy we can
    smp.runOnce(rng.cycleAllEntropy);

    logger.debug("halting...", .{});
    util.halt();
}

fn printsmth() void {
    const kib = memory.pmm.used() * 4;
    logger.info("{} KiB ({} MiB) used", .{ kib, kib / 1024 });
}

// STANDARD LIBRARY IMPLEMENTATIONS

pub const std_options = std.Options{
    .page_size_max = memory.max_page_size,
    .page_size_min = memory.min_page_size,
};

pub const os = struct {
    pub const heap = struct {
        pub const page_allocator = memory.page_allocator;
    };
};

pub const panic = std.debug.FullPanic(log.panic);
