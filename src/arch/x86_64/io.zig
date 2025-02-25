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

pub inline fn insl(port: u16, addr: anytype, cnt: usize) void {
    asm volatile ("cld; repne; insl;"
        : [addr] "={edi}" (addr),
          [cnt] "={ecx}" (cnt),
        : [port] "{dx}" (port),
          [addr] "0" (addr),
          [cnt] "1" (cnt),
        : "memory", "cc"
    );
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

pub inline fn delay() void {
    out(u8, 0x80, 0);
}
