pub inline fn in(comptime T: type, addr: usize) T {
    return @as(*const T, @ptrFromInt(addr)).*;
}

pub inline fn ins(comptime T: type, addr: usize, len: usize) [len]T {
    return @as([*]T, @ptrFromInt(addr))[0..len].*;
}

pub inline fn out(comptime T: type, addr: usize, value: T) void {
    @as(*T, @ptrFromInt(addr)).* = value;
}
