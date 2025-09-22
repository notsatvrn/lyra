const std = @import("std");

// BASIC UTILITIES

pub inline fn wfi() void {
    asm volatile ("hlt");
}

pub fn halt() noreturn {
    @branchHint(.cold);
    disableInterrupts();
    while (true) wfi();
}

pub inline fn disableInterrupts() void {
    asm volatile ("cli");
    // non-maskable interrupts
    // out(u8, 0x70, in(u8, 0x70) & 0x7F);
    // _ = in(u8, 0x71);
}

pub inline fn enableInterrupts() void {
    asm volatile ("sti");
    // non-maskable interrupts
    // out(u8, 0x70, in(u8, 0x70) | 0x80);
    // _ = in(u8, 0x71);
}

pub inline fn delay() void {
    out(u8, 0x80, 0);
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
              [value] "{al}" (value),
        ),
        u16 => asm volatile ("mov %[value], %" ++ reg ++ ":%[addr]"
            :
            : [addr] "+m" (addr),
              [value] "{ax}" (value),
        ),
        u32 => asm volatile ("mov %[value], %" ++ reg ++ ":%[addr]"
            :
            : [addr] "+m" (addr),
              [value] "{eax}" (value),
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
            : [value] "{al}" (value),
        ),
        u16 => asm volatile ("mov %[value], %" ++ reg
            :
            : [value] "{ax}" (value),
        ),
        u32 => asm volatile ("mov %[value], %" ++ reg
            :
            : [value] "{eax}" (value),
        ),
        u64 => asm volatile ("mov %[value], %" ++ reg
            :
            : [value] "{rax}" (value),
        ),
        else => @compileError("invalid type (must be u8, u16, u32, u64)"),
    }
}

// I/O PORTS

pub inline fn in(comptime T: type, port: u16) T {
    return switch (T) {
        u8 => asm volatile ("inb %[port], %[result]"
            : [result] "={al}" (-> u8),
            : [port] "N{dx}" (port),
        ),
        u16 => asm volatile ("inw %[port], %[result]"
            : [result] "={ax}" (-> u16),
            : [port] "N{dx}" (port),
        ),
        u32 => asm volatile ("inl %[port], %[result]"
            : [result] "={eax}" (-> u32),
            : [port] "N{dx}" (port),
        ),
        else => @compileError("invalid value (must be u8, u16, u32)"),
    };
}

pub inline fn ins(comptime T: type, port: u16, len: usize) [len]T {
    var data: [len]T = undefined;
    const addr = @intFromPtr(&data);

    const suffix = switch (T) {
        u8 => "b",
        u16 => "w",
        u32 => "l",
        else => @compileError("invalid type (must be u8, u16, u32)"),
    };

    asm volatile ("cld; repne; ins" ++ suffix ++ ";"
        : [addr] "={edi}" (addr),
          [len] "={ecx}" (len),
        : [port] "{dx}" (port),
          [addr] "0" (addr),
          [len] "1" (len),
        : .{ .memory = true, .cc = true });

    return data;
}

pub inline fn out(comptime T: type, port: u16, value: T) void {
    switch (T) {
        u8 => asm volatile ("outb %[value], %[port]"
            :
            : [value] "{al}" (value),
              [port] "N{dx}" (port),
        ),
        u16 => asm volatile ("outw %[value], %[port]"
            :
            : [value] "{ax}" (value),
              [port] "N{dx}" (port),
        ),
        u32 => asm volatile ("outl %[value], %[port]"
            :
            : [value] "{eax}" (value),
              [port] "N{dx}" (port),
        ),
        else => @compileError("invalid type (must be u8, u16, u32)"),
    }
}

// MODEL SPECIFIC REGISTERS

pub inline fn rdmsr(msr: u32) u64 {
    var lo: u32 = 0;
    var hi: u32 = 0;

    asm volatile (
        \\rdmsr
        : [lo] "={eax}" (lo),
          [hi] "={edx}" (hi),
        : [msr] "{ecx}" (msr),
    );

    return (@as(u64, hi) << 32) | @as(u64, lo);
}

pub inline fn wrmsr(msr: u32, value: u64) void {
    const lo: u32 = @truncate(value);
    const hi: u32 = @truncate(value >> 32);

    asm volatile (
        \\wrmsr
        : [lo] "{eax}" (lo),
          [hi] "{edx}" (hi),
          [msr] "{ecx}" (msr),
    );
}
