//! The virtual memory management system. Handles mapping in kernel space.

const std = @import("std");

pub const PageTable = @import("PageTable.zig");

const smp = @import("../smp.zig");
const UsedSet = @import("UsedSet.zig");
const memory = @import("../memory.zig");
const limine = @import("../limine.zig");

const logger = @import("../log.zig").Logger{ .name = "vmm" };

pub var tables: []PageTable = undefined;
pub var sets: []UsedSet = undefined;
var offset: usize = 0;

const page_size = memory.PageSize.small;
const page_mask = page_size.bytes() - 1;

pub fn init() void {
    // start mapping right after kernel
    const kaddr = limine.kaddr.response.virtual;
    const ksize = limine.kfile.response.file.size;
    offset = (kaddr + ksize + page_mask) & ~page_mask;

    tables = memory.allocator.alloc(PageTable, smp.count()) catch unreachable;
    for (tables) |*t| {
        t.* = .{ .top = undefined };
        t.load();
    }

    sets = memory.allocator.alloc(UsedSet, smp.count()) catch unreachable;
    const pages = (std.math.maxInt(usize) - offset) >> page_size.shift();
    for (sets) |*o| o.* = UsedSet.init(memory.allocator, pages) catch unreachable;
}

/// Picks a spot in memory after the kernel to map in. Uses small pages.
pub fn mapSimple(phys: usize, len: usize, flags: ?PageTable.Entry) usize {
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

pub fn map(phys: ?usize, virt: usize, len: usize, size: memory.PageSize, flags: ?PageTable.Entry) void {
    const current = smp.getCpu();
    const table = &tables[current];
    table.map(phys, virt, len, size, flags) catch
        logger.panic("map failed on cpu {}", .{current});
    table.store();
    // reflect changes in other cpu's tables
    if (!smp.launched) {
        @branchHint(.unlikely);
        for (1..smp.count()) |cpu|
            tables[cpu].map(phys, virt, len, size, flags) catch
                logger.panic("map failed", .{});
    }
}
