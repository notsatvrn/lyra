pub const pmm = @import("memory/pmm.zig");
pub const vmm = @import("memory/vmm.zig");

// MATH UTILITIES

pub const KB = 1024;
pub const MB = KB * 1024;
pub const GB = MB * 1024;
pub const TB = GB * 1024;
pub const PB = TB * 1024;

pub const PageSize = enum(u2) {
    small = 1, // 4KB
    medium = 2, // 2MB
    large = 3, // 1GB

    pub inline fn multiplier(self: PageSize) usize {
        return @intFromEnum(self) / @intFromEnum(PageSize.small);
    }

    pub inline fn shift(self: PageSize) u5 {
        return 3 + @as(u5, @intFromEnum(self)) * 9;
    }

    pub inline fn bytes(self: PageSize) usize {
        return @as(usize, 1) << self.shift();
    }
};

pub const min_page_size = PageSize.small.bytes();
pub const max_page_size = PageSize.large.bytes();

pub inline fn pagesNeeded(bytes: usize, self: PageSize) usize {
    const shift = self.shift();
    const page_size = @as(usize, 1) << shift;
    return (bytes + page_size - 1) >> shift;
}

// BASIC ALLOCATORS

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

pub var ready = false;

pub const PageAllocator = struct {
    pub const vtable = Allocator.VTable{
        .alloc = alloc,
        .resize = resize,
        .remap = realloc,
        .free = free,
    };

    fn alloc(_: *anyopaque, n: usize, _: Alignment, _: usize) ?[*]u8 {
        std.debug.assert(n > 0);
        if (n >= std.math.maxInt(usize) - min_page_size) return null;
        const block = pmm.map(.small, pagesNeeded(n, .small));
        return @ptrCast(block orelse return null);
    }

    inline fn _remap(buf: []u8, new_len: usize, may_move: bool) ?[*]u8 {
        const old_pages = pagesNeeded(buf.len, .small);
        const new_pages = pagesNeeded(new_len, .small);
        const block = pmm.remap(buf.ptr, .small, old_pages, new_pages, may_move);
        return @ptrCast(block orelse return null);
    }

    fn resize(_: *anyopaque, buf: []u8, _: Alignment, new_len: usize, _: usize) bool {
        return _remap(buf, new_len, false) != null;
    }

    fn realloc(_: *anyopaque, buf: []u8, _: Alignment, new_len: usize, _: usize) ?[*]u8 {
        return _remap(buf, new_len, true);
    }

    fn free(_: *anyopaque, slice: []u8, _: Alignment, _: usize) void {
        const pages = pagesNeeded(slice.len, .small);
        _ = pmm.unmap(slice.ptr, .small, pages);
    }
};

pub const page_allocator = Allocator{
    .ptr = undefined,
    .vtable = &PageAllocator.vtable,
};

pub const binned = @import("memory/binned_allocator.zig");
const GlobalAllocator = binned.BinnedAllocator(.{ .thread_safe = true });
var global_allocator = GlobalAllocator.init;

pub const allocator = if (builtin.is_test)
    std.testing.allocator
else
    global_allocator.allocator();
