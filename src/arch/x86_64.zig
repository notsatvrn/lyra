pub const boot = @import("x86_64/boot.zig");
pub const util = @import("x86_64/util.zig");
pub const time = @import("x86_64/time.zig");
pub const paging = @import("x86_64/paging.zig");

// VGA TEXT MODE STUFF

pub inline fn textModeAddr() usize {
    return 0xB8000;
}

const io = @import("x86_64/io.zig");
const TextMode = @import("../tty/TextMode.zig");

pub inline fn updateTextModeCursor(state: TextMode) void {
    if (!state.cursor) return;

    io.out(u8, 0x3D4, 0x0F);
    io.out(u8, 0x3D5, @truncate(state.pos));
    io.out(u8, 0x3D4, 0x0E);
    io.out(u8, 0x3D5, @truncate(state.pos >> 8));
}

// MISCELLANEOUS STUFF

pub const prepCPUs = @import("x86_64/gdt.zig").update;
pub const setCPU = @import("x86_64/gdt.zig").load;
pub const getCPU = @import("x86_64/gdt.zig").str;

pub const pciDetect = @import("x86_64/pci.zig").detect;
