// Memory-mapped I/O implementation, same interface as x86 port-mapped I/O
// Separated from arch because all arches will use it (primary I/O for RISC)

pub const Port = usize;

pub inline fn in(comptime T: type, port: Port) T {
    return @as(*const T, @ptrFromInt(port)).*;
}

pub inline fn ins(comptime T: type, port: Port, len: usize) [len]T {
    return @as([*]T, @ptrFromInt(port))[0..len].*;
}

pub inline fn out(comptime T: type, port: Port, value: T) void {
    @as(*T, @ptrFromInt(port)).* = value;
}
