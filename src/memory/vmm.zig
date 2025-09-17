//! The virtual memory management system.
//!
//! Here you'll find structures and functions related to page tables,
//! the kernel virtual memory layout, memory-mapped I/O, etc.

const std = @import("std");
const memory = @import("../memory.zig");

pub const ManagedPageTable = @import("ManagedPageTable.zig");

/// Kernel virtual memory structures.
pub const kernel = struct {
    const smp = @import("../smp.zig");
    const Storage = smp.LocalStorage;
    const logger = @import("../log.zig").Logger{ .name = "vmm/kernel" };

    pub var tables: Storage(ManagedPageTable) = undefined;
    pub var offsets: Storage(usize) = undefined;

    pub fn init(offset: usize) void {
        tables = Storage(ManagedPageTable).init(memory.allocator) catch unreachable;
        for (tables.objects) |*t| t.load();
        offsets = Storage(usize).init(memory.allocator) catch unreachable;
        for (offsets.objects) |*o| o.* = offset;
    }

    /// Picks a spot in memory after the kernel to map in. Uses small pages.
    pub fn mapIo(phys: usize, len: usize, flags: ManagedPageTable.Entry) usize {
        const offset = offsets.get();
        // align offset to a page
        offset.* = (offset.* + 0xFFF) & ~@as(usize, 0xFFF);
        // do the mapping
        const virt = offset.*;
        map(phys, virt, len, .small, flags);
        // move the offset by a page
        offset.* += (len + 0xFFF) & ~@as(usize, 0xFFF);

        return virt;
    }

    pub fn map(phys: usize, virt: usize, len: usize, size: memory.PageSize, flags: ManagedPageTable.Entry) void {
        const table = tables.get();
        table.map(phys, virt, len, size, flags) catch
            logger.panic("map failed on cpu {}", .{smp.getCpu()});
        table.store();
    }

    pub fn unmap(virt: usize, len: usize, size: memory.PageSize) void {
        const table = tables.get();
        table.unmap(virt, len, size) catch
            logger.panic("unmap failed on cpu {}", .{smp.getCpu()});
        table.store();
    }
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
