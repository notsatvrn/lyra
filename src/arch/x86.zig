pub const gdt = @import("x86/gdt.zig");
pub const a20 = @import("x86/a20.zig");
pub const io = @import("x86/io.zig");
pub const util = @import("x86/util.zig");
pub const vga = @import("x86/vga.zig");
pub const tty = vga;

pub const halt = util.halt;

// -- BOOTING --

// heap (TODO: use pages)

const std = @import("std");
const BufferHeap = std.heap.FixedBufferAllocator;

var heap_buf: [0x10000]u8 = undefined;
pub var heap: BufferHeap = undefined;

// multiboot info

const multiboot = @import("../multiboot.zig");
const BootInfo = multiboot.BootInfo;

var s2_magic: u32 = undefined;
var s2_info: *const BootInfo = undefined;

// entrypoint

comptime {
    asm (
        \\.intel_syntax noprefix
        \\
        \\.text
        \\.global _start
        \\.type _start, @function
        \\
        \\_start:
        \\  lea esp, [stack_top]
        \\
        \\  push ebx
        \\  push eax
        \\
        \\  call stage1
        \\  call halt
        \\
        \\.att_syntax prefix
    );
}

export fn stage1(magic: u32, info: *const BootInfo) noreturn {
    vga.clear();
    vga.print("-- Stage 1 (Real Mode) --\n\n");

    vga.print("Disabling all interrupts...\n");
    util.disablePICInterrupts();
    util.disableInterrupts();

    vga.print("Initializing GDT...\n");
    gdt.init();

    vga.print("Entering protected mode...\n");

    s2_magic = magic;
    s2_info = info;
    asm volatile (
        \\mov %cr0, %eax
        \\or 1, %al
        \\mov %eax, %cr0
        \\jmp stage2
    );

    unreachable;
}

export fn stage2() noreturn {
    vga.print("\n-- Stage 2 (Protected Mode) --\n\n");

    vga.print("Ensuring A20 line is enabled...\n");
    if (!a20.enable()) {
        // TODO: panic function
        vga.print("A20 gate not responding, unable to boot.");
        util.halt();
    }

    vga.print("Loading TSS into task register...\n");
    gdt.loadTSS();

    vga.print("Initializing heap...\n");
    heap = BufferHeap.init(&heap_buf);

    vga.print("\n-- Stage 3 (kmain) --\n\n");
    @import("../kmain.zig").kmain(s2_magic, s2_info);
}
