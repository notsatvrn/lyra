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
    const Tables = smp.LocalStorage(ManagedPageTable);
    const UsedSet = @import("UsedSet.zig");
    const Sets = smp.LocalStorage(UsedSet);
    const limine = @import("../limine.zig");

    const logger = @import("../log.zig").Logger{ .name = "vmm/kernel" };

    pub var tables: Tables = undefined;
    pub var sets: Sets = undefined;
    var offset: usize = 0;

    const page_size = memory.PageSize.small;
    const page_mask = page_size.bytes() - 1;

    pub fn init(start: usize) void {
        offset = (start + page_mask) & ~page_mask;

        tables = Tables.init() catch unreachable;
        for (tables.objects) |*t| t.load();

        sets = Sets.init() catch unreachable;
        const pages = (std.math.maxInt(usize) - offset) >> page_size.shift();
        for (sets.objects) |*o| o.* = UsedSet.init(memory.allocator, pages) catch unreachable;
    }

    /// Picks a spot in memory after the kernel to map in. Uses small pages.
    pub fn mapSimple(phys: usize, len: usize, flags: ManagedPageTable.Entry) usize {
        const set = sets.get();
        const pages = memory.pagesNeeded(len, .small);
        const start = set.claimRange(pages) orelse return 0;
        const virt = offset + start * page_size.bytes();

        map(phys, virt, len, .small, flags);

        if (!smp.launched) {
            @branchHint(.unlikely);
            for (1..limine.cpus.response.count) |cpu|
                _ = sets.objects[cpu].claimRange(pages);
        }

        return virt;
    }

    pub fn map(phys: usize, virt: usize, len: usize, size: memory.PageSize, flags: ManagedPageTable.Entry) void {
        if (smp.launched) {
            @branchHint(.likely);
            return mapCpu(smp.getCpu(), phys, virt, len, size, flags);
        }
        for (0..limine.cpus.response.count) |cpu|
            mapCpu(cpu, phys, virt, len, size, flags);
    }

    pub fn unmap(virt: usize, len: usize, size: memory.PageSize) void {
        if (smp.launched) {
            @branchHint(.likely);
            return unmapCpu(smp.getCpu(), virt, len, size);
        }
        for (0..limine.cpus.response.count) |cpu|
            unmapCpu(cpu, virt, len, size);
    }

    // CPU-SPECIFIC MAPPING

    inline fn mapCpu(cpu: usize, phys: usize, virt: usize, len: usize, size: memory.PageSize, flags: ManagedPageTable.Entry) void {
        const table = &tables.objects[cpu];
        table.map(phys, virt, len, size, flags) catch
            logger.panic("map failed on cpu {}", .{cpu});
        table.store();
    }

    inline fn unmapCpu(cpu: usize, virt: usize, len: usize, size: memory.PageSize) void {
        const table = &tables.objects[cpu];
        table.unmap(virt, len, size) catch
            logger.panic("unmap failed on cpu {}", .{cpu});
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
