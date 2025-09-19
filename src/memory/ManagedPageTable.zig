//! A mutable page table with a pool allocator for entries.

const std = @import("std");

const memory = @import("../memory.zig");
const Size = memory.PageSize;
const paging = @import("paging.zig");
const PageTable = paging.PageTable;
pub const Entry = paging.Entry;

top: *PageTable,
pool: paging.Pool = .{},

const Self = @This();

// INIT / DEINIT

pub inline fn init() !Self {
    var self = Self{ .top = undefined };
    self.top = try self.pool.create();
    return self;
}

pub inline fn deinit(self: *Self) void {
    self.unmap(0, std.math.maxInt(usize), .large);
    self.pool.deinit();
    self.* = undefined;
}

// READ OPERATIONS

pub inline fn load(self: *Self) void {
    self.top = paging.load();
}

pub inline fn store(self: Self) void {
    paging.store(self.top);
}

pub inline fn physFromVirt(self: Self, addr: usize) ?usize {
    return paging.physFromVirt(self.top, addr);
}

// WRITE OPERATIONS

const limine = @import("../limine.zig");

/// Map a section of virtual memory to a physical address.
pub fn map(self: *Self, phys: usize, virt: usize, len: usize, size: Size, flags: Entry) !void {
    try self.mapInner(phys, virt, len, size, flags.getFlags(true));
}

/// Unmap a section of virtual memory.
pub fn unmap(self: *Self, virt: usize, len: usize, size: Size) !void {
    try self.mapInner(null, virt, len, size, .{});
}

inline fn mapInner(self: *Self, phys: ?usize, virt: usize, len: usize, size: Size, flags: Entry) !void {
    const size_mask = size.bytes() - 1;

    var offset = virt & size_mask;
    var phys_page: ?usize = null;
    if (phys) |addr| {
        // get offset from phys instead
        offset = addr & size_mask;
        phys_page = addr & ~size_mask;
    }
    const virt_page = virt & ~size_mask;
    // offset + len, rounded up to a full page
    const len_real = (offset + len + size_mask) & ~size_mask;
    const end = virt_page + len_real - 1;

    const level: u3 = @truncate(4 + limine.paging_mode.response.mode); // 1 = level 5
    try paging.mapRecursive(self.top, &self.pool, level, virt_page, end, phys_page, size, flags);
}
