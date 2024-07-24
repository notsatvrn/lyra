const io = @import("io.zig");

pub inline fn disablePICInterrupts() void {
    io.out(0xA1, @as(u8, 0xFF));
    io.delay();
    io.out(0x21, @as(u8, 0xFB));
    io.delay();
}

pub inline fn disableInterrupts() void {
    asm volatile ("cli");
    io.out(0x70, io.in(u8, 0x70) & 0x7F);
    _ = io.in(u8, 0x71);
}

pub inline fn enableInterrupts() void {
    asm volatile ("sti");
    io.out(0x70, io.in(u8, 0x70) | 0x80);
    _ = io.in(u8, 0x71);
}

pub export fn halt() noreturn {
    @setCold(true);
    while (true) asm volatile ("hlt");
}
