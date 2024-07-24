// https://wiki.osdev.org/A20_Line
//
// Enabling the A20 line allows us to access memory beyond 1MB.
// It is often disabled by default, resulting in a wraparound for addresses over 0x100000.
//
// Some code borrowed from the Linux kernel (licensed under GPL-2.0)
// https://github.com/torvalds/linux/blob/master/arch/x86/boot/a20.c

const io = @import("io.zig");
const tty = @import("vga.zig");

// CHECKING

////
// Returns true if the A20 line is enabled.
// This works using an odd megabyte address (EDI) to its even megabyte neighbor (ESI).
// The address in EDI should wrap around when doing a memory move into it, making the value at both addresses equal.
// Then we compare the values at the two addresses. If equal, address wraparound occured, meaning the A20 line is disabled.
// Method by Elad Ashkcenazi. Only works under protected mode.
//
fn check() bool {
    return !asm volatile (
        \\.intel_syntax noprefix
        \\
        \\mov edi, 0x112345
        \\mov esi, 0x012345
        \\mov [esi], esi
        \\mov [edi], edi
        \\
        \\xor al, al
        \\cmpsd
        \\jne A20_on
        \\mov al, 1
        \\A20_on:
        \\
        \\.att_syntax prefix
        : [res] "={al}" (-> bool),
        :
        : "edi", "esi", "al"
    );
}

// ENABLING

// Helper function for A20 line enablement via the keyboard controller.
fn empty8042() bool {
    var ffs: usize = 32;
    var i: usize = 0;
    while (i < 100000) : (i += 1) {
        io.delay();

        const status = io.in(u8, 0x64);

        // FF is a plausible, but very unlikely status
        if (status == 0xFF) {
            ffs -= 1;
            // Assume no keyboard controller present
            if (ffs == 0) return false;
        }

        if (status & 1 == 1) {
            // Read and discard input data
            io.delay();
            _ = io.in(u8, 0x60);
        } else if (status & 2 == 0) {
            // Buffers empty, finished!
            return true;
        }
    }

    return false;
}

// zig fmt: off

// Enable the A20 line via the keyboard controller.
inline fn enableKBC() void {
    _ = empty8042();

    io.out(0x64, @as(u8, 0xD1));    // Command write
    _ = empty8042();

    io.out(0x60, @as(u8, 0xDF));    // A20 on
    _ = empty8042();

    io.out(0x64, @as(u8, 0xFF));    // Null command, but UHCI wants it
    _ = empty8042();
}

// Enable the A20 line via the FAST A20 option.
inline fn enableFast() void {
    var port_a = io.in(u8, 0x92);   // Configuration port A
    port_a |=  0x02;                // Enable A20
    port_a &= ~@as(u8, 0x01);       // Don't reset the machine
    io.out(0x92, port_a);
}

// zig fmt: on

////
// Enable the A20 line.
// Attempts 256 times using all available methods.
//
pub fn enable() bool {
    var i: u8 = 0;
    while (i < 255) : (i += 1) {
        if (check()) return true;

        // try BIOS interrupt

        //enableBIOS();
        //io.delay();
        //if (check()) return true;

        // try keyboard controller

        const kbc_err = empty8042();
        // BIOS interrupt may have late reaction
        // empty8042() will waste some time so check again
        if (check()) return true;

        if (!kbc_err) {
            enableKBC();
            if (check()) return true;
        }

        // try FAST A20 option

        enableFast();
        if (check()) return true;
    }

    return false;
}
