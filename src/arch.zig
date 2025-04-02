const builtin = @import("builtin");

const arch = switch (builtin.cpu.arch) {
    .x86_64 => @import("arch/x86_64.zig"),
    .aarch64 => @import("arch/aarch64.zig"),
    .riscv64 => @import("arch/riscv64.zig"),
    else => unreachable,
};

comptime {
    @import("std").mem.doNotOptimizeAway(arch);
}

pub const boot = arch.boot;
pub const time = arch.time;
pub const paging = arch.paging;
pub const io = arch.io;

pub const text_mode: ?type = if (@hasDecl(arch, "text_mode")) arch.text_mode else null;

pub const prepCPUs = arch.prepCPUs;
pub const setCPU = arch.setCPU;
pub const getCPU = arch.getCPU;

pub const pciDetect = arch.pciDetect;

pub const halt = arch.halt;
