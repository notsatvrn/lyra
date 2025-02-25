// https://wiki.osdev.org/Interrupt_Service_Routines
//
// Original code from Andrea Orru's Zen kernel project (reboot branch)
// https://github.com/AndreaOrru/zen/blob/reboot/kernel/src/interrupt/isr.zig

const std = @import("std");
const idt = @import("idt.zig");

/// Interrupt Stack Frame.
pub const InterruptStack = packed struct {
    // General purpose registers.
    // zig fmt: off
    r15: u64, r14: u64, r13: u64, r12: u64,
    r11: u64, r10: u64, r9:  u64, r8:  u64,
    rbp: u64, rdi: u64, rsi: u64,
    rdx: u64, rcx: u64, rbx: u64, rax: u64,
    // zig fmt: on

    // Interrupt vector number.
    interrupt_number: u64,
    // Associated error code, or 0.
    error_code: u64,

    // Registers pushed by the CPU when an interrupt is fired.
    rip: u64,
    cs: u64,
    rflags: u64,
    rsp: u64,
    ss: u64,
};

/// Pointer to the stack that will be used by the kernel to handle interrupts.
/// Referenced from assembly (`isr_stubs.s`).
export var kernel_stack: *u64 = undefined;
/// Pointer to the stack that was in use when an interrupt occurred.
/// Referenced from assembly (`isr_stubs.s`).
pub export var context: *InterruptStack = undefined;

// Get the stack pointer.
inline fn readRsp() u64 {
    var value: u64 = undefined;
    asm volatile ("mov %rsp, %[value]"
        : [value] "=r" (value),
    );
    return value;
}

/// Installs the Interrupt Service Routines into the IDT.
pub fn install() void {
    // The Limine bootloader provides us with a stack that is at least 64KB.
    // We pick an address somewhere in that range to use as the kernel stack.
    kernel_stack = @ptrFromInt(readRsp() - 0x1000);

    // Exceptions and IRQs.
    inline for (0..48) |i| {
        // Using @extern and an inline loop to save space.
        // Plus, it's a pretty neat feature I wanted to try out.
        const name = std.fmt.comptimePrint("isr{}", .{i});
        const func = @extern(*const IsrFunction, .{ .name = name });
        idt.setupGate(i, .kernel, func);
    }

    // Syscalls.
    idt.setupGate(128, .user, isr128);
}

// Interrupt Service Routines are defined in assembly (in `isr_stubs.s`).
// We declare them here to be able to reference them from Zig.
pub const IsrFunction = @TypeOf(isr128);
extern fn isr128() void;
