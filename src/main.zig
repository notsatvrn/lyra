const std = @import("std");

const limine = @import("limine.zig");
const arch = @import("arch.zig");
const memory = @import("memory.zig");
const pci = @import("pci.zig");
const cpus = @import("cpus.zig");

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

    // initial setup + memory

    arch.boot.setup();
    arch.paging.saveTable();
    memory.init();

    // now we have memory, bring up more framebuffers and init double-buffering

    logger.info("doing fb extended setup", .{});
    fbExtendedSetup();

    // build pci device tree and bring up cpus

    pci.detect() catch |e| log.panic(null, "pci device detection failed: {}", .{e});
    pci.print() catch |e| log.panic(null, "pci device printing failed: {}", .{e});
    cpus.init() catch |e| log.panic(null, "cpu init failed: {}", .{e});

    logger.info("no work left to do, halting", .{});

    tty.sync();

    arch.halt();
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
