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
    const Offsets = smp.LocalStorage(usize);
    const limine = @import("../limine.zig");

    const logger = @import("../log.zig").Logger{ .name = "vmm/kernel" };

    pub var tables: Tables = undefined;
    pub var offsets: Offsets = undefined;

    pub fn init(offset: usize) void {
        // 16MiB minimum memory requirement, should never OOM
        tables = Tables.init() catch unreachable;
        offsets = Offsets.init() catch unreachable;
        for (tables.objects) |*t| t.load();
        for (offsets.objects) |*o| o.* = offset;
    }

    /// Picks a spot in memory after the kernel to map in. Uses small pages.
    pub fn mapSimple(phys: usize, len: usize, flags: ManagedPageTable.Entry) usize {
        const offset = offsets.get();
        // align offset to a page
        offset.* = (offset.* + 0xFFF) & ~@as(usize, 0xFFF);
        // do the mapping
        const virt = offset.*;
        map(phys, virt, len, .small, flags);
        // move the offset by a page
        offset.* += (len + 0xFFF) & ~@as(usize, 0xFFF);
        // set the new offset if pre-smp
        if (!smp.launched) {
            @branchHint(.unlikely);
            for (1..limine.cpus.response.count) |cpu|
                offsets.objects[cpu] = offset.*;
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
