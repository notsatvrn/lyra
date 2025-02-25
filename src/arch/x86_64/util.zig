const std = @import("std");

const io = @import("io.zig");

const log = @import("../../log.zig");
const logger = log.Logger{ .name = "x86-64/util" };

// BASIC UTILITIES

pub export fn halt() noreturn {
    @branchHint(.cold);
    disableInterrupts();
    while (true) asm volatile ("hlt");
}

pub inline fn disablePICInterrupts() void {
    io.out(u8, 0xA1, 0xFF);
    io.delay();
    io.out(u8, 0x21, 0xFB);
    io.delay();
}

pub inline fn enablePICInterrupts() void {
    io.out(u8, 0xA1, 0xFF);
    io.delay();
    io.out(u8, 0x21, 0xFB);
    io.delay();
}

pub inline fn disableInterrupts() void {
    asm volatile ("cli");
    //io.out(u8, 0x70, io.in(u8, 0x70) & 0x7F);
    //_ = io.in(u8, 0x71);
}

pub inline fn enableInterrupts() void {
    asm volatile ("sti");
    //io.out(u8, 0x70, io.in(u8, 0x70) | 0x80);
    //_ = io.in(u8, 0x71);
}
