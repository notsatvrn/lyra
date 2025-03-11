//! The physical memory management system.
//!
//! All we do here is split up memory into pages and track which ones are
//! in active use. No permissions or other garbage here, just the basics.
//!
//! Despite that, the implementation is far from simple. I've tried my best
//! to provide ample documentation but I'm happy to add more if needed.

const builtin = @import("builtin");
const std = @import("std");
const assert = std.debug.assert;
const maxInt = std.math.maxInt;

const limine = @import("limine.zig");

const log = @import("log.zig");
const logger = log.Logger{ .name = "memory" };

// MATH UTILITIES

pub const KB = 1024;
pub const MB = KB * 1024;
pub const GB = MB * 1024;
pub const TB = GB * 1024;
pub const PB = TB * 1024;

pub const page_size = 4 * KB;

pub inline fn pagesNeeded(bytes: usize) usize {
    return (bytes + (page_size - 1)) / page_size;
}

// REGION STRUCTURE

pub const Ptr = [*]align(page_size) [page_size]u8;
pub const Block = []align(page_size) [page_size]u8;

pub const Region = struct {
    const UsedSet = @import("memory/UsedSet.zig");
    const Lock = @import("util/lock.zig").Lock;

    ptr: Ptr,
    set: UsedSet,
    lock: Lock = .{},

    const Self = @This();

    comptime {
        // let's keep things small.
        assert(@sizeOf(Self) <= 48);
    }

    // OPERATIONS

    pub fn allocBlock(self: *Self, n: usize) ?Ptr {
        self.lock.lock();
        defer self.lock.unlock();

        if (self.set.claimRange(n)) |index| {
            const ptr = self.ptr + index;
            return ptr;
        } else return null;
    }

    pub fn resizeBlock(self: *Self, block: Block, new_len: usize, comptime may_move: bool) ?Ptr {
        assert(@intFromPtr(block.ptr) >= @intFromPtr(self.ptr));

        if (new_len <= block.len) return block.ptr;

        self.lock.lock();
        defer self.lock.unlock();

        const start = block.ptr - self.ptr;
        const resized = self.set.resizeRange(start, block.len, new_len);
        if (resized) return block.ptr;
        if (!may_move) return null;

        self.set.unclaimRange(start, block.len);
        const new_start = self.set.claimRange(new_len) orelse return null;
        const new_block = self.ptr + new_start;
        @memcpy(new_block[0..block.len], block);
        return new_block;
    }

    pub fn freeBlock(self: *Self, block: [][page_size]u8) void {
        assert(@intFromPtr(block.ptr) >= @intFromPtr(self.ptr));

        self.lock.lock();
        defer self.lock.unlock();

        self.set.unclaimRange(block.ptr - self.ptr, block.len);
    }
};

// MEMORY DIRECTORY

// we use a single page to store all region data
// can hold up to like 85 regions at the moment
// if we go over that something is probably wrong
const max_regions = page_size / @sizeOf(Region);
var regions: []Region = undefined;
var total: usize = 0;

pub inline fn init() void {
    var usable: usize = 0;

    var largest: []u8 = "";
    var bitsets_size: usize = 0;

    for (0..limine.mmap.response.count) |i| {
        const entry = limine.mmap.response.entries[i];
        if (entry.type != .usable) continue;

        const pages = entry.len / page_size;
        // align bitset length to 64-bits (8 bytes) for optimization
        // allows us to iterate through the bitset by entire integers
        bitsets_size += (pages + 63) / 64;

        // put the address in Limine's higher-half direct map
        // absolutely required, if we don't do this writes cause crashes
        entry.ptr = limine.convertPointer(entry.ptr);

        // find the largest region and put region info at the start
        if (entry.len > largest.len) largest = entry.ptr[0..entry.len];

        usable += 1;
    }

    // setup regions

    var len = usable;
    if (usable > max_regions) {
        logger.warn("unable to map all memory regions", .{});
        len = max_regions;
    }

    regions = @as([*]Region, @ptrCast(@alignCast(largest.ptr)))[0..len];

    // write regions

    var b: [*]u64 = @ptrCast(@alignCast(largest.ptr + page_size));
    std.crypto.secureZero(u64, b[0..bitsets_size]);

    var s: usize = 0;
    for (0..limine.mmap.response.count) |i| {
        const entry = limine.mmap.response.entries[i];
        if (entry.type != .usable) continue;

        const pages = entry.len / page_size;
        var region = Region{
            .ptr = @ptrCast(@alignCast(entry.ptr)),
            .set = .{ .ptr = b, .len = pages },
        };

        // mark pages holding region info as used
        if (largest.ptr == entry.ptr) {
            const pages_needed = pagesNeeded(bitsets_size * 8) + 1;
            region.set.used += pages_needed;
            region.set.tail = pages_needed;
            for (0..pages_needed) |j| {
                const byte = j / 8;
                const offset: u3 = @truncate(j);
                b[byte] |= @as(u8, 1) << offset;
            }
        }

        // perf: order regions from largest -> smallest
        // - increases chance of finding available pages in first region
        // - gives us more memory if one page can't hold all regions
        if (pages > regions[0].set.len) {
            std.mem.copyBackwards(
                Region,
                regions[1..regions.len],
                regions[0 .. regions.len - 1],
            );

            regions[0] = region;
        } else regions[s] = region;

        total += pages;
        // align bitset len (rationale above)
        b += (pages + 63) / 64;
        s += 1;
    }

    logger.info("{}/{} KiB used", .{ used() * 4, total * 4 });

    // test

    logger.debug("testing page allocator", .{});
    var alloc = page_allocator.alloc(u8, page_size) catch @panic("page alloc failed");
    alloc = page_allocator.realloc(alloc, page_size * 3) catch @panic("page realloc failed");
    page_allocator.free(alloc);

    // bench

    if (false) @import("memory/bench.zig").run();
}

// REGION UTILITIES

pub inline fn used() usize {
    var sum: usize = 0;
    for (regions) |region|
        sum += region.set.used;

    return sum;
}

pub inline fn unused() usize {
    return total - used();
}

// search in regions until we find one containing an existing block
// may return null if no regions contain the block (rare but possible)
inline fn findBlockRegion(block: Block) ?*Region {
    const addr = @intFromPtr(block.ptr);
    for (0..regions.len) |i| {
        const region = &regions[i];

        region.lock.lockShared();
        defer region.lock.unlockShared();

        if (region.set.used < block.len) continue;

        const start = @intFromPtr(region.ptr);
        const end = start + (region.set.len * page_size);

        if (addr >= start and addr < end)
            return region;
    }

    return null;
}

// OPERATIONS

pub fn allocBlock(n: usize) ?Ptr {
    for (regions) |*region| {
        if (region.allocBlock(n)) |ptr| return ptr;
    }

    return null;
}

pub fn resizeBlock(block: Block, new_len: usize, comptime may_move: bool) ?Ptr {
    if (new_len <= block.len) return block.ptr;
    const region = findBlockRegion(block) orelse return null;
    return region.resizeBlock(block, new_len, may_move);
}

pub fn freeBlock(block: Block) bool {
    const region = findBlockRegion(block) orelse return false;
    region.freeBlock(block);
    return true;
}

// BASIC ALLOCATORS

const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

pub const PageAllocator = struct {
    pub const vtable = Allocator.VTable{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn alloc(_: *anyopaque, n: usize, _: Alignment, _: usize) ?[*]u8 {
        assert(n > 0);
        if (n >= maxInt(usize) - page_size) return null;
        const block = allocBlock(pagesNeeded(n));
        return @ptrCast(block orelse return null);
    }

    inline fn realloc(buf: []u8, new_len: usize, comptime may_move: bool) ?[*]u8 {
        const ptr: Ptr = @ptrCast(@alignCast(buf.ptr));
        const old_pages = pagesNeeded(buf.len);
        const new_pages = pagesNeeded(new_len);
        const block = resizeBlock(ptr[0..old_pages], new_pages, may_move);
        return @ptrCast(block orelse return null);
    }

    fn resize(_: *anyopaque, buf: []u8, _: Alignment, new_len: usize, _: usize) bool {
        return realloc(buf, new_len, false) != null;
    }

    fn remap(_: *anyopaque, buf: []u8, _: Alignment, new_len: usize, _: usize) ?[*]u8 {
        return realloc(buf, new_len, true);
    }

    fn free(_: *anyopaque, slice: []u8, _: Alignment, _: usize) void {
        const ptr: Ptr = @ptrCast(@alignCast(slice.ptr));
        const pages = pagesNeeded(slice.len);
        // TODO: handle invalid frees
        _ = freeBlock(ptr[0..pages]);
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
