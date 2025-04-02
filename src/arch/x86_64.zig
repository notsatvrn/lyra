pub const boot = @import("x86_64/boot.zig");
pub const time = @import("x86_64/time.zig");
pub const paging = @import("x86_64/paging.zig");
pub const io = @import("x86_64/io.zig");

// VGA TEXT MODE

pub const text_mode = struct {
    pub inline fn address() usize {
        return 0xB8000;
    }

    const TextMode = @import("../tty/TextMode.zig");

    pub inline fn updateCursor(state: *const TextMode) void {
        if (!state.cursor) return;

        io.out(u8, 0x3D4, 0x0F);
        io.out(u8, 0x3D5, @truncate(state.pos));
        io.out(u8, 0x3D4, 0x0E);
        io.out(u8, 0x3D5, @truncate(state.pos >> 8));
    }
};

// MISCELLANEOUS STUFF

pub const prepCPUs = @import("x86_64/gdt.zig").update;
pub const setCPU = @import("x86_64/gdt.zig").load;
pub const getCPU = @import("x86_64/gdt.zig").str;

pub const pciDetect = @import("x86_64/pci.zig").detect;

const util = @import("x86_64/util.zig");
pub const wfi = util.wfi;
pub const halt = util.halt;
