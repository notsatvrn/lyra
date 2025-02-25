const builtin = @import("builtin");

const arch = switch (builtin.cpu.arch) {
    .x86_64 => @import("arch/x86_64.zig"),
    else => unreachable,
};

comptime {
    @import("std").mem.doNotOptimizeAway(arch);
}

pub const boot = arch.boot;
pub const time = arch.time;
pub const paging = arch.paging;

pub const halt = arch.util.halt;

pub const textModeAddr = arch.textModeAddr;
pub const updateTextModeCursor = arch.updateTextModeCursor;

pub const prepCPUs = arch.prepCPUs;
pub const setCPU = arch.setCPU;
pub const getCPU = arch.getCPU;

pub const pciDetect = arch.pciDetect;
