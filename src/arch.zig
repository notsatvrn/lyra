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
pub const clock = arch.clock;
pub const timing = arch.timing;
pub const paging = arch.paging;
pub const util = arch.util;

pub const text_mode: ?type = if (@hasDecl(arch, "text_mode")) arch.text_mode else null;

pub const prepCpus = arch.prepCpus;
pub const setCpu = arch.setCpu;
pub const getCpu = arch.getCpu;

pub const pciDetect = arch.pciDetect;
