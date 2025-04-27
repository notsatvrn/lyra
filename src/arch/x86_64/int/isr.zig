// https://wiki.osdev.org/Interrupt_Service_Routines
//
// Original code from Andrea Orru's Zen kernel project (reboot branch)
// https://github.com/AndreaOrru/zen/blob/reboot/kernel/src/interrupt/isr.zig

const std = @import("std");
const idt = @import("idt.zig");
const gdt = @import("../gdt.zig");
const memory = @import("../../../memory.zig");

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

/// Pointer to the stack that was in use when an interrupt occurred.
/// Referenced from assembly (`isr_stubs.s`).
pub export var context: *InterruptStack = undefined;

var kernel_stacks_init: [1]*u64 = .{undefined};
var kernel_stacks: []*u64 = kernel_stacks_init[0..];
/// Returns the pointer to the stack that will be used by the kernel to handle interrupts.
/// Referenced from assembly (`isr_stubs.s`).
export fn getStack() *u64 {
    return kernel_stacks[gdt.str()];
}

// Get the stack pointer.
inline fn readRsp() u64 {
    var value: u64 = undefined;
    asm volatile ("mov %rsp, %[value]"
        : [value] "=r" (value),
    );
    return value;
}

// Reallocate kernel_stacks with a stack pointer for each CPU.
pub inline fn newStacks(cpus: usize) !void {
    kernel_stacks = try memory.allocator.alloc(*u64, cpus);
}

// Store a stack pointer for the current CPU in kernel_stacks.
pub inline fn setupCPU(cpu: usize) void {
    // The Limine bootloader provides us with a stack that is at least 64KB.
    // We pick an address somewhere in that range to use as the kernel stack.
    kernel_stacks[cpu] = @ptrFromInt(readRsp() - 0x1000);
}

/// Installs the Interrupt Service Routines into the IDT.
pub fn install() void {
    // Exceptions and IRQs.
    inline for (0..48) |i| {
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
