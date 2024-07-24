const builtin = @import("builtin");

const arch = switch (builtin.cpu.arch) {
    .x86 => @import("arch/x86.zig"),
    else => unreachable,
};

pub usingnamespace arch;

comptime {
    const std = @import("std");

    std.debug.assert(@hasDecl(arch, "heap"));
    std.debug.assert(@hasDecl(arch, "halt"));
}
