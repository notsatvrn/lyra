const multiboot = @import("multiboot.zig");
const arch = @import("arch.zig");
const tty = arch.tty;
const std = @import("std");
const io = @import("arch/x86/io.zig");

export const multiboot_header align(4) linksection(".multiboot") = multiboot.Header{};

pub export fn kmain(magic: u32, info: *const multiboot.BootInfo) noreturn {
    if (magic != multiboot.info_magic) {
        tty.print("Bad multiboot magic! Unable to boot.\n");
        arch.halt();
    } else {
        tty.print("Valid multiboot magic!\n");
    }

    tty.printf("Multiboot flags: 0b{b}\n", .{info.flags});

    if ((info.flags >> 6) & 1 == 1) {
        tty.print("\nAvailable memory sections (multiboot mmap):\n");

        var total: u64 = 0;
        var addr = info.mmap_addr;
        var i: u32 = 0;

        while (i < info.mmap_length) : (i += 1) {
            const section: *const multiboot.RawEntry = @ptrFromInt(addr);
            addr += section.size + 4;
            if (section.len == 0 or section.typ != 1) continue;

            tty.printf("addr: 0x{X} | len: 0x{X}\n", .{ section.addr, section.len });
            total += section.len;
        }

        tty.printf("Total available memory: {d}MB", .{total / (1024 * 1024)});
    }

    arch.halt();
}
