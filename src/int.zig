// https://wiki.osdev.org/Interrupts
//
// Original code from Andrea Orru's Zen kernel project (main & reboot branch)
// https://github.com/AndreaOrru/zen/blob/main/kernel/interrupt.zig
// https://github.com/AndreaOrru/zen/blob/reboot/kernel/src/interrupt/isr.zig

pub const idt = @import("int/idt.zig");
pub const isr = @import("int/isr.zig");
pub const InterruptStack = isr.InterruptStack;

const std = @import("std");
const util = @import("util.zig");

// PROGRAMMABLE INTERRUPT CONTROLLER
// https://wiki.osdev.org/8259_PIC

// zig fmt: off
// PIC ports.
const PIC1_CMD  = 0x20;
const PIC1_DATA = 0x21;
const PIC2_CMD  = 0xA0;
const PIC2_DATA = 0xA1;
// PIC commands.
const ISR_READ  = 0x0B;  // Read the In-Service Register.
const EOI       = 0x20;  // End of Interrupt.
// Initialization Control Words commands.
const ICW1_INIT = 0x10;
const ICW1_ICW4 = 0x01;
const ICW4_8086 = 0x01;
// zig fmt: on

// https://wiki.osdev.org/8259_PIC#Initialisation
pub inline fn remapPIC(offset1: u8, offset2: u8) void {
    const a1 = util.in(u8, PIC1_DATA); // save masks
    const a2 = util.in(u8, PIC2_DATA);

    util.out(u8, PIC1_CMD, ICW1_INIT | ICW1_ICW4); // starts the initialization sequence (in cascade mode)
    util.delay();
    util.out(u8, PIC2_CMD, ICW1_INIT | ICW1_ICW4);
    util.delay();
    util.out(u8, PIC1_DATA, offset1); // ICW2: Primary PIC vector offset
    util.delay();
    util.out(u8, PIC2_DATA, offset2); // ICW2: Secondary PIC vector offset
    util.delay();
    util.out(u8, PIC1_DATA, 4); // ICW3: tell Primary PIC that there is a secondary PIC at IRQ2 (0000 0100)
    util.delay();
    util.out(u8, PIC2_DATA, 2); // ICW3: tell Secondary PIC its cascade identity (0000 0010)
    util.delay();

    util.out(u8, PIC1_DATA, ICW4_8086); // ICW4: have the PICs use 8086 mode (and not 8080 mode)
    util.delay();
    util.out(u8, PIC2_DATA, ICW4_8086);
    util.delay();

    util.out(u8, PIC1_DATA, a1); // restore saved masks.
    util.out(u8, PIC2_DATA, a2);
}

pub inline fn disablePIC() void {
    // mask all interrupts
    util.out(u8, PIC1_DATA, 0xFF);
    util.out(u8, PIC2_DATA, 0xFF);
}

// INTERRUPT HANDLERS

/// Number of CPU exceptions.
const NUM_EXCEPTIONS = 32;
/// Interrupt vector number of the first exception.
const EXCEPTION_0 = 0;
/// Interrupt vector number of the last exception.
const EXCEPTION_31 = EXCEPTION_0 + NUM_EXCEPTIONS - 1;

/// Number of IRQs.
const NUM_IRQS = 16;
/// Interrupt vector number of the first IRQ.
const IRQ_0 = EXCEPTION_31 + 1;
/// Interrupt vector number of the last IRQ.
const IRQ_15 = IRQ_0 + NUM_IRQS - 1;

/// Canonical names for CPU exceptions.
const EXCEPTION_NAMES = [NUM_EXCEPTIONS][]const u8{
    "Division Error",
    "Debug",
    "Non-maskable Interrupt",
    "Breakpoint",
    "Overflow",
    "Bound Range Exceeded",
    "Invalid Opcode",
    "Device Not Available",
    "Double Fault",
    "Coprocessor Segment Overrun",
    "Invalid TSS",
    "Segment Not Present",
    "Stack-Segment Fault",
    "General Protection Fault",
    "Page Fault",
    "Reserved",
    "x87 Floating-Point Exception",
    "Alignment Check",
    "Machine Check",
    "SIMD Floating-Point Exception",
    "Virtualization Exception",
    "Control Protection Exception",
    "Reserved",
    "Reserved",
    "Reserved",
    "Reserved",
    "Reserved",
    "Reserved",
    "Hypervisor Injection Exception",
    "VMM Communication Exception",
    "Security Exception",
    "Reserved",
};

/// Generic interrupt handler function.
const Handler = fn (*InterruptStack) callconv(.c) void;
/// IRQ interrupt handler function. Inlined for the wrapper.
const IRQHandler = fn (*InterruptStack) callconv(.@"inline") void;

/// Interrupt handlers table. Referenced from assembly (`int/isr_stubs.s`).
export var handlers = [_]*const Handler{unhandled} ** (NUM_EXCEPTIONS + NUM_IRQS);

/// Default handler for unregistered interrupt vectors.
fn unhandled(stack: *InterruptStack) callconv(.c) noreturn {
    var n = stack.interrupt_number;

    switch (n) {
        EXCEPTION_0...EXCEPTION_31 => {
            n -= EXCEPTION_0;
            std.debug.panic("Unhandled exception: {s} ({} | {b})", .{ EXCEPTION_NAMES[n], n, stack.error_code });
        },

        IRQ_0...IRQ_15 => {
            n -= IRQ_0;
            std.debug.panic("Unhandled IRQ: {}", .{n});
        },

        else => {
            std.debug.panic("Invalid interrupt: {}", .{n});
        },
    }
}

/// Registers an interrupt handler.
///
/// Parameters:
///     n:       Interrupt number.
///     handler: Interrupt handler, or `null` for the default handler.
pub inline fn register(n: u8, handler: ?Handler) void {
    handlers[n] = if (handler) |h| &h else unhandled;
}

/// Register an IRQ handler.
///
/// Parameters:
///     irq: Index of the IRQ.
///     handler: IRQ handler.
///     mask: Mask during execution?
pub fn registerIRQ(irq: u4, handler: ?IRQHandler) void {
    if (handler) |h| {
        const wrapper = struct {
            fn wrapped(stack: *InterruptStack) callconv(.c) void {
                const i: u4 = @truncate(stack.interrupt_number - IRQ_0);
                maskIRQ(i, true);
                h(stack);
                maskIRQ(i, false);
                signalPIC(i);
            }
        };

        handlers[IRQ_0 + @as(u8, irq)] = wrapper.wrapped;
        maskIRQ(irq, false);
    } else {
        maskIRQ(irq, true);
        handlers[IRQ_0 + @as(u8, irq)] = unhandled;
    }
}

/// Mask/unmask an IRQ.
///
/// Parameters:
///     irq: Index of the IRQ.
///     mask: Whether to mask (true) or unmask (false).
pub fn maskIRQ(irq: u4, mask: bool) void {
    // Figure out if primary or secondary PIC owns the IRQ.
    const port: u16 = if (irq < 8) PIC1_DATA else PIC2_DATA;
    const old = util.in(u8, port); // Retrieve the current mask.

    // Mask or unmask the interrupt.
    const shift: u3 = @truncate(irq % 8);
    if (mask) {
        util.out(u8, port, old | (@as(u8, 1) << shift));
    } else {
        util.out(u8, port, old & ~(@as(u8, 1) << shift));
    }
}

// Tells the PIC that our interrupt is done.
inline fn signalPIC(irq: u4) void {
    if (irq >= 8) {
        // Signal to the secondary PIC.
        util.out(u8, PIC2_CMD, EOI);
    }
    // Signal to the primary PIC.
    util.out(u8, PIC1_CMD, EOI);
}
