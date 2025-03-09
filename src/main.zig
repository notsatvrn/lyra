const std = @import("std");

const limine = @import("limine.zig");
const arch = @import("arch.zig");
const memory = @import("memory.zig");
const pci = @import("pci.zig");
const smp = @import("smp.zig");

const gfx = @import("gfx.zig");
const tty = @import("tty.zig");
const log = @import("log.zig");
const logger = log.Logger{ .name = "main" };

// ENTRYPOINT

export fn _start() callconv(.c) noreturn {
    arch.boot.init();

    // setup logging

    const framebuffers = limine.fb.response;

    if (framebuffers.count == 0) {
        const addr = arch.textModeAddr();
        tty.out = tty.Output.initTextMode(addr);
    } else {
        // start logging to the smallest framebuffer
        // when we bring up more, they'll mirror this one
        var smallest = framebuffers.entries[0];

        for (0..framebuffers.count) |i| {
            const this = framebuffers.entries[i];

            if (this.width < smallest.width and
                this.height < smallest.height)
                smallest = this;
        }

        const mode = smallest.defaultVideoMode();
        tty.out = tty.Output.initRawFB(smallest.ptr, &mode);
    }

    tty.out.clear();

    arch.boot.setup();
    arch.paging.saveTable();
    memory.init();
    fbExtendedSetup();
    pci.detect() catch |e| log.panic(null, "pci device detection failed: {}", .{e});
    pci.print() catch |e| log.panic(null, "pci device printing failed: {}", .{e});
    smp.init() catch |e| log.panic(null, "smp init failed: {}", .{e});

    arch.halt();
}

// WIP
fn efiStuff() void {
    std.os.uefi.system_table = limine.efi_system_table.response.ptr;
    std.os.uefi.system_table.runtime_services = limine.convertPointer(std.os.uefi.system_table.runtime_services);
    std.os.uefi.system_table.runtime_services.resetSystem = limine.convertPointer(std.os.uefi.system_table.runtime_services.resetSystem);
    std.os.uefi.system_table.runtime_services.setVirtualAddressMap = limine.convertPointer(std.os.uefi.system_table.runtime_services.setVirtualAddressMap);

    const efi_mmap = limine.efi_memory_map.response;
    const map_size = efi_mmap.memmap_size / efi_mmap.desc_size;

    const map = memory.allocator.alloc(std.os.uefi.tables.MemoryDescriptor, map_size) catch log.panic(null, "failed to allocate new efi virtual map", .{});

    var efi_mmap_iter = limine.EFIMemoryMapIterator{};
    var index: usize = 0;
    while (efi_mmap_iter.next()) |desc| {
        map[index] = desc.*;
        map[index].virtual_start = map[index].physical_start | limine.hhdm.response.offset;
        index += 1;
    }

    _ = std.os.uefi.system_table.runtime_services.setVirtualAddressMap(map_size, @sizeOf(std.os.uefi.tables.MemoryDescriptor), @intCast(limine.efi_memory_map.response.desc_version), map.ptr);

    for (0..5) |i| {
        logger.info("resetting in {}", .{5 - i});
        arch.time.stall(std.time.ns_per_s);
    }

    std.os.uefi.system_table.runtime_services.resetSystem(.reset_shutdown, .success, 0, null);
}

inline fn fbExtendedSetup() void {
    const framebuffers = limine.fb.response;
    if (framebuffers.count == 0) return;

    // set current framebuffer to mirror a virtual framebuffer (double-buffering)

    const smallest = tty.out.rawfb;
    const s_buffer = smallest.buffer;

    var mode = s_buffer.mode.*;
    mode.pitch = mode.width * s_buffer.bytes;
    var new_out = tty.Output.initVirtFB(&mode) catch return;

    new_out.virtfb.base.render = smallest.render;
    new_out.virtfb.base.cursor = smallest.cursor;
    new_out.virtfb.initMirroring(s_buffer) catch return;

    defer tty.out = new_out;

    // add additional mirrors

    if (framebuffers.count == 1) return;

    for (0..framebuffers.count) |i| {
        const new = framebuffers.entries[i];
        const new_mode = new.defaultVideoMode();
        const new_buffer = gfx.Framebuffer.init(new.ptr, &new_mode);
        new_out.virtfb.addMirror(new_buffer) catch break;
    }
}

// STANDARD LIBRARY IMPLEMENTATIONS

pub const std_options = std.Options{
    .page_size_max = memory.page_size,
    .page_size_min = memory.page_size,
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
