pub const boot = @import("x86_64/boot.zig");
pub const clock = @import("x86_64/clock.zig");
pub const timing = @import("x86_64/timing.zig");
pub const paging = @import("x86_64/paging.zig");
pub const util = @import("x86_64/util.zig");

// VGA TEXT MODE

pub const text_mode = struct {
    pub inline fn address() usize {
        return 0xB8000;
    }

    const TextMode = @import("../tty/TextMode.zig");
    const io = @import("x86_64/io.zig");

    pub inline fn updateCursor(state: *const TextMode) void {
        if (!state.cursor) return;

        io.out(u8, 0x3D4, 0x0F);
        io.out(u8, 0x3D5, @truncate(state.pos));
        io.out(u8, 0x3D4, 0x0E);
        io.out(u8, 0x3D5, @truncate(state.pos >> 8));
    }
};

// MULTI-PROCESSOR HELPERS

const gdt = @import("x86_64/gdt.zig");
const isr = @import("x86_64/int/isr.zig");

pub fn prepCpus(cpus: usize) !void {
    try gdt.update(cpus);
    try isr.newStacks(cpus);
}

pub fn setCpu(cpu: usize) void {
    gdt.load(cpu);
    isr.setupCpu(cpu);
}

pub const getCpu = gdt.str;

// MISCELLANEOUS STUFF

pub const pciDetect = @import("x86_64/pci.zig").detect;
