const std = @import("std");

const arch = @import("../arch.zig").paging;
const PageTable = arch.PageTable;
const Entry = arch.Entry;

pool: std.heap.MemoryPool(Entry),
table: *PageTable,

const Self = @This();

pub inline fn load(self: *Self) void {
    self.table = arch.load();
}

pub inline fn store(self: Self) void {
    arch.store(self.table);
}

pub inline fn physFromVirt(self: Self, addr: usize) ?usize {
    return arch.physFromVirt(self.table, addr);
}
