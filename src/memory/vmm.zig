//! The virtual memory management system. Handles mapping in kernel space.

const std = @import("std");

pub const paging = @import("paging.zig");
pub const ManagedPageTable = @import("ManagedPageTable.zig");

const smp = @import("../smp.zig");
const UsedSet = @import("UsedSet.zig");
const memory = @import("../memory.zig");
const limine = @import("../limine.zig");

const logger = @import("../log.zig").Logger{ .name = "vmm" };

pub var tables: []ManagedPageTable = undefined;
pub var sets: []UsedSet = undefined;
var offset: usize = 0;

const page_size = memory.PageSize.small;
const page_mask = page_size.bytes() - 1;

pub fn init() void {
    // start mapping right after kernel
    const kaddr = limine.kaddr.response.virtual;
    const ksize = limine.kfile.response.file.size;
    offset = (kaddr + ksize + page_mask) & ~page_mask;

    tables = memory.allocator.alloc(ManagedPageTable, smp.count()) catch unreachable;
    for (tables) |*t| t.* = .{ .top = paging.load() };

    sets = memory.allocator.alloc(UsedSet, smp.count()) catch unreachable;
    const pages = (std.math.maxInt(usize) - offset) >> page_size.shift();
    for (sets) |*o| o.* = UsedSet.init(memory.allocator, pages) catch unreachable;
}

/// Picks a spot in memory after the kernel to map in. Uses small pages.
pub fn mapSimple(phys: usize, len: usize, flags: ManagedPageTable.Entry) usize {
    const set = &sets[smp.getCpu()];
    const pages = memory.pagesNeeded(len, .small);
    const start = set.claimRange(pages) orelse return 0;
    const virt = offset + start * page_size.bytes();

    map(phys, virt, len, .small, flags);

    if (!smp.launched) {
        @branchHint(.unlikely);
        for (1..smp.count()) |cpu| _ = sets[cpu].claimRange(pages);
    }

    return virt;
}

pub fn map(phys: usize, virt: usize, len: usize, size: memory.PageSize, flags: ManagedPageTable.Entry) void {
    if (smp.launched) {
        @branchHint(.likely);
        return mapCpu(smp.getCpu(), phys, virt, len, size, flags);
    }
    for (0..smp.count()) |cpu| mapCpu(cpu, phys, virt, len, size, flags);
}

pub fn unmap(virt: usize, len: usize, size: memory.PageSize) void {
    if (smp.launched) {
        @branchHint(.likely);
        return unmapCpu(smp.getCpu(), virt, len, size);
    }
    for (0..smp.count()) |cpu| unmapCpu(cpu, virt, len, size);
}

// CPU-SPECIFIC MAPPING

inline fn mapCpu(cpu: usize, phys: usize, virt: usize, len: usize, size: memory.PageSize, flags: ManagedPageTable.Entry) void {
    const table = &tables[cpu];
    table.map(phys, virt, len, size, flags) catch
        logger.panic("map failed on cpu {}", .{cpu});
    if (cpu == smp.getCpu()) table.store();
}

inline fn unmapCpu(cpu: usize, virt: usize, len: usize, size: memory.PageSize) void {
    const table = &tables[cpu];
    table.unmap(virt, len, size) catch
        logger.panic("unmap failed on cpu {}", .{cpu});
    if (cpu == smp.getCpu()) table.store();
}
