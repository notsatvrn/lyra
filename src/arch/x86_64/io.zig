// I/O implementation on x86-64 (legacy port-mapped I/O)

pub const Port = u16;

pub inline fn in(comptime T: type, port: Port) T {
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

pub inline fn ins(comptime T: type, port: Port, len: usize) [len]T {
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
        : "memory", "cc"
    );

    return data;
}

pub inline fn out(comptime T: type, port: Port, value: T) void {
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
