//! The virtual memory management system.
//!
//! Here you'll find structures and functions related to page tables,
//! the kernel virtual memory layout, memory-mapped I/O, etc.

const std = @import("std");
const memory = @import("../memory.zig");

pub const ManagedPageTable = @import("ManagedPageTable.zig");

/// Kernel virtual memory structures.
pub const kernel = struct {
    const Lock = @import("utils").lock.SpinSharedLock;

    pub var page_table: ManagedPageTable = .{ .top = undefined };
    pub var page_table_lock: Lock = .{};
    pub var mmio_start: usize = 0;
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
