//! A mutable page table with a pool allocator for entries.

const std = @import("std");

const memory = @import("../memory.zig");
const Size = memory.PageSize;
const paging = @import("../arch.zig").paging;
const PageTable = paging.PageTable;
pub const Entry = paging.Entry;

top: *PageTable,
pool: paging.Pool = .{},

const Self = @This();

// INIT / DEINIT

pub inline fn init() !Self {
    const top = try memory.page_allocator.create(PageTable);
    return .{ .top = top };
}

pub inline fn fromUnmanaged(top: *PageTable) Self {
    return .{ .top = top };
}

pub inline fn deinit(self: Self) void {
    memory.page_allocator.destroy(self.top);
}

// READ OPERATIONS

pub fn store(self: Self) void {
    paging.store(self.top);
}

pub inline fn physFromVirt(self: Self, addr: usize) ?usize {
    return paging.physFromVirt(self.top, addr);
}

// WRITE OPERATIONS

const limine = @import("../limine.zig");

/// Map a section of virtual memory to a physical address.
pub fn map(self: *Self, phys: ?usize, virt: usize, len: usize, size: Size, flags: Entry) !void {
    const size_bytes = size.bytes();
    const page_mask = size_bytes - 1;

    var offset = virt & page_mask;
    var phys_page: ?usize = null;
    if (phys) |addr| {
        // get offset from phys instead
        offset = addr & page_mask;
        phys_page = addr & ~page_mask;
    }
    const virt_page = virt & ~page_mask;
    // offset + len, rounded up to a full page
    const len_real = (offset + len + size_bytes) & ~page_mask;
    const end = virt_page + len_real - 1;

    const level = limine.pagingLevels();
    const f = flags.getFlags(true);

    try paging.mapRecursive(self.top, &self.pool, level, virt_page, end, phys_page, size, f);
}

/// Unmap a section of virtual memory.
pub inline fn unmap(self: *Self, virt: usize, len: usize, size: Size) !void {
    try self.map(null, virt, len, size, undefined);
}
