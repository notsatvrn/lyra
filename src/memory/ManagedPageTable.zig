//! A mutable page table with a pool allocator for entries.

const std = @import("std");

const memory = @import("../memory.zig");
const Size = memory.PageSize;
const paging = @import("../arch.zig").paging;
const PageTable = paging.PageTable;
pub const Entry = paging.Entry;

top: *PageTable,

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

pub fn map(self: *Self, phys: usize, virt: usize, len: usize, size: Size, options: Entry) !void {
    const size_bytes = size.bytes();
    const page_mask = size_bytes - 1;

    const offset = phys & page_mask;
    const phys_page = phys & ~page_mask;
    const virt_page = virt & ~page_mask;
    // offset + len, rounded up to a full page
    const len_real = (offset + len + size_bytes) & ~page_mask;
    const end = virt_page + len_real - 1;

    try paging.mapRecursive(self.top, limine.pagingLevels(), virt_page, end, phys_page, size, options.makeBase());
}

pub fn unmap(self: *Self, virt: usize, len: usize, size: Size, options: Entry) void {
    const size_bytes = size.bytes();
    const page_mask = size_bytes - 1;

    const offset = virt & page_mask;
    const virt_page = virt & ~page_mask;
    // offset + len, rounded up to a full page
    const len_real = (offset + len + size_bytes) & ~page_mask;
    const pages = len_real >> size.shift();

    paging.unmap(self.top, virt_page, pages, size, options.makeBase());
}
