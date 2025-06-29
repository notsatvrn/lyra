const std = @import("std");

const limine = @import("limine.zig");
const arch = @import("arch.zig");
const memory = @import("memory.zig");
const smp = @import("smp.zig");
const clock = @import("clock.zig");
const pci = @import("pci.zig");
const acpi = @import("acpi.zig");

const gfx = @import("gfx.zig");
const tty = @import("tty.zig");
const log = @import("log.zig");
const logger = log.Logger{ .name = "main" };

// ENTRYPOINT

var tty_init_tm: tty.TextMode = undefined;

export fn _start() callconv(.c) noreturn {
    arch.util.disableInterrupts();
    arch.boot.init();

    // setup logging

    const framebuffers = limine.fb.response;

    if (framebuffers.count == 0) {
        if (arch.text_mode) |tm| {
            tty_init_tm = tty.TextMode.initAddr(tm.address());
            tty.generic = tty_init_tm.generic();
        }
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
        tty.framebuffer = tty.Framebuffer.init(smallest.ptr, &mode);
    }

    tty.clear();
    arch.boot.setup();
    // sanity check, should always work
    arch.paging.store(arch.paging.load());
    memory.init();
    smp.init() catch |e| log.panic(null, "smp init failed: {}", .{e});
    arch.util.enableInterrupts();
    clock.setup();
    @import("memory/bench.zig").run();

    if (framebuffers.count != 0) fbsetup: {
        // set current framebuffer to mirror a virtual framebuffer (double-buffering)

        const smallest = tty.framebuffer.?.basic;
        const s_buffer = smallest.buffer;

        var mode = s_buffer.mode.*;
        mode.pitch = mode.width * s_buffer.bytes;
        var new_fb = tty.Framebuffer.initVirtual(&mode) catch break :fbsetup;

        new_fb.advanced.base.render = smallest.render;
        new_fb.advanced.base.cursor = smallest.cursor;
        new_fb.advanced.initMirroring(s_buffer) catch break :fbsetup;

        defer tty.framebuffer = new_fb;

        // add additional mirrors

        if (framebuffers.count == 1) break :fbsetup;

        for (0..framebuffers.count) |i| {
            const new = framebuffers.entries[i];
            const new_mode = new.defaultVideoMode();
            const new_buffer = gfx.Framebuffer.init(new.ptr, &new_mode);
            new_fb.advanced.addMirror(new_buffer) catch break;
        }
    }

    pci.detect() catch |e| log.panic(null, "pci device detection failed: {}", .{e});
    pci.print() catch |e| log.panic(null, "pci device printing failed: {}", .{e});
    acpi.sdt_start = limine.rsdp.response.ptr.sdt();

    while (true) arch.util.wfi();
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
