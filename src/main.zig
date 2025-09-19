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

    logger.info("bootloader was {s} {s}", .{
        limine.bootldr.response.name,
        limine.bootldr.response.version,
    });

    logger.info("identify processor...", .{});
    cpuid.identify();
    logger.info("- vendor is {s}", .{@tagName(cpuid.vendor)});
    if (cpuid.features.x2apic)
        logger.info("- x2apic is supported", .{});

    memory.pmm.init();
    memory.vmm.kernel.init();
    memory.ready = true;

    tty.virtualize();

    acpi.init();
    util.enableInterrupts();
    clock.init();
    util.disableInterrupts();
    rng.init();
    pci.init();

    smp.launch(stage2);
}

fn stage2() noreturn {
    const cpu = smp.getCpu();

    memory.vmm.kernel.tables.get().load();
    rng.clockEntropy();

    // get all the entropy we can
    if (cpu == 0) rng.cycleAllEntropy();

    logger.debug("cpu {} halting...", .{cpu});

    util.halt();
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

fn panicWrapper(msg: []const u8, first_trace_addr: ?usize) noreturn {
    log.panic(first_trace_addr, "{s}", .{msg});
}

pub const panic = std.debug.FullPanic(panicWrapper);
