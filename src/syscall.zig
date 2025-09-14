const isr = @import("int/isr.zig");

pub const handlers = [_]fn () void{};

// Wraps a function into a syscall handler.
fn Syscall(comptime func: anytype) fn () void {
    const typ = @typeInfo(@TypeOf(func));
    if (typ != .@"fn") @compileError("syscall type must be function");
    const params = typ.@"fn".params;

    return struct {
        fn arg(comptime n: u3) (params[n].type orelse void) {
            const T = params[n].type orelse void;
            if (T == void) return;

            const value = switch (n) {
                0 => isr.context.rdi,
                1 => isr.context.rsi,
                2 => isr.context.rdx,
                3 => isr.context.rcx,
                4 => isr.context.r8,
                5 => isr.context.r9,
            };

            const info = @typeInfo(T);
            return switch (info) {
                .bool => value != 0,
                .int => @intCast(value),
                .float => @floatCast(@as(f64, @bitCast(value))),
                .pointer => @ptrFromInt(value),
            };
        }

        pub fn wrapper() void {
            const result = switch (params.len) {
                0 => func(),
                1 => func(arg(0)),
                2 => func(arg(0), arg(1)),
                3 => func(arg(0), arg(1), arg(2)),
                4 => func(arg(0), arg(1), arg(2), arg(3)),
                5 => func(arg(0), arg(1), arg(2), arg(3), arg(4)),
                6 => func(arg(0), arg(1), arg(2), arg(3), arg(4), arg(5)),
                else => @compileError("syscall can have at most 6 args"),
            };

            if (@TypeOf(result) != void) {
                const info = @typeInfo(@TypeOf(result));
                isr.context.rax = switch (info) {
                    .int => @intCast(result),
                    .float => @bitCast(@as(f64, @floatCast(result))),
                    .pointer => @intFromPtr(result),
                };
            }
        }
    }.wrapper;
}
