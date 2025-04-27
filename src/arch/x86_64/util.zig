const std = @import("std");
const io = @import("io.zig");

// BASIC UTILITIES

pub inline fn wfi() void {
    asm volatile ("hlt");
}

pub fn halt() noreturn {
    @branchHint(.cold);
    disableInterrupts();
    while (true) asm volatile ("hlt");
}

pub inline fn disablePICInterrupts() void {
    io.out(u8, 0xA1, 0xFF);
    delay();
    io.out(u8, 0x21, 0xFB);
    delay();
}

pub inline fn enablePICInterrupts() void {
    io.out(u8, 0xA1, 0xFF);
    delay();
    io.out(u8, 0x21, 0xFB);
    delay();
}

pub inline fn disableInterrupts() void {
    asm volatile ("cli");
    // non-maskable interrupts
    //io.out(u8, 0x70, io.in(u8, 0x70) & 0x7F);
    //_ = io.in(u8, 0x71);
}

pub inline fn enableInterrupts() void {
    asm volatile ("sti");
    // non-maskable interrupts
    //io.out(u8, 0x70, io.in(u8, 0x70) | 0x80);
    //_ = io.in(u8, 0x71);
}

pub inline fn delay() void {
    io.out(u8, 0x80, 0);
}

// REGISTER UTILITIES

pub inline fn readRegister(comptime T: type, comptime reg: []const u8, addr: usize) T {
    return switch (T) {
        u8 => asm volatile ("mov %" ++ reg ++ ":%[addr], %[out]"
            : [out] "=q" (-> u8),
            : [addr] "m" (addr),
        ),
        u16 => asm volatile ("mov %" ++ reg ++ ":%[addr], %[out]"
            : [out] "=r" (-> u16),
            : [addr] "m" (addr),
        ),
        u32 => asm volatile ("mov %" ++ reg ++ ":%[addr], %[out]"
            : [out] "=r" (-> u32),
            : [addr] "m" (addr),
        ),
        else => @compileError("invalid type (must be u8, u16, u32)"),
    };
}

pub inline fn writeRegister(comptime T: type, comptime reg: []const u8, addr: usize, value: T) void {
    switch (T) {
        u8 => asm volatile ("mov %[value], %" ++ reg ++ ":%[addr]"
            :
            : [addr] "+m" (addr),
              [value] "qi" (value),
        ),
        u16 => asm volatile ("mov %[value], %" ++ reg ++ ":%[addr]"
            :
            : [addr] "+m" (addr),
              [value] "ri" (value),
        ),
        u32 => asm volatile ("mov %[value], %" ++ reg ++ ":%[addr]"
            :
            : [addr] "+m" (addr),
              [value] "ri" (value),
        ),
        else => @compileError("invalid type (must be u8, u16, u32)"),
    }
}

pub inline fn getRegister(comptime T: type, comptime reg: []const u8) T {
    return switch (T) {
        u8 => asm volatile ("mov %" ++ reg ++ ", %[out]"
            : [out] "=q" (-> u8),
        ),
        u16 => asm volatile ("mov %" ++ reg ++ ", %[out]"
            : [out] "=r" (-> u16),
        ),
        u32 => asm volatile ("mov %" ++ reg ++ ", %[out]"
            : [out] "=r" (-> u32),
        ),
        u64 => asm volatile ("mov %" ++ reg ++ ", %[out]"
            : [out] "=r" (-> u64),
        ),
        else => @compileError("invalid type (must be u8, u16, u32, u64)"),
    };
}

pub inline fn setRegister(comptime T: type, comptime reg: []const u8, value: T) void {
    switch (T) {
        u8 => asm volatile ("mov %[value], %" ++ reg
            :
            : [value] "qi" (value),
        ),
        u16 => asm volatile ("mov %[value], %" ++ reg
            :
            : [value] "ri" (value),
        ),
        u32 => asm volatile ("mov %[value], %" ++ reg
            :
            : [value] "ri" (value),
        ),
        u64 => asm volatile ("mov %[value], %" ++ reg
            :
            : [value] "ri" (value),
        ),
        else => @compileError("invalid type (must be u8, u16, u32, u64)"),
    }
}
