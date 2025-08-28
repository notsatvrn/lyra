//! The virtual memory management system.
//!
//! Here you'll find structures and functions related to page tables,
//! the kernel virtual memory layout, memory-mapped I/O, etc.

const std = @import("std");
const memory = @import("memory.zig");

pub const ManagedPageTable = @import("memory/ManagedPageTable.zig");

/// Kernel virtual memory structures.
pub const kernel = struct {
    const paging = @import("arch.zig").paging;
    const Lock = @import("utils").lock.SpinSharedLock;

    pub var page_table: ManagedPageTable = undefined;
    pub const addr_space_end = std.math.maxInt(usize);
    pub var mmio_start: usize = addr_space_end - (memory.TB - 1);
    pub var page_table_lock: Lock = .{};
};

pub const io = struct {
    pub inline fn in(comptime T: type, addr: usize) T {
        return @as(*const T, @ptrFromInt(addr)).*;
    }

    pub inline fn ins(comptime T: type, addr: usize, len: usize) [len]T {
        return @as([*]T, @ptrFromInt(addr))[0..len].*;
    }

    pub inline fn out(comptime T: type, addr: usize, value: T) void {
        @as(*T, @ptrFromInt(addr)).* = value;
    }
};
