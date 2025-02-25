//! The physical memory management system.
//!
//! All we do here is split up memory into pages and track which ones are
//! in active use. No permissions or other garbage here, just the basics.
//!
//! Despite that, the implementation is far from simple. I've tried my best
//! to provide ample documentation but I'm happy to add more if needed.

pub const UsedSet = @import("memory/UsedSet.zig");

const builtin = @import("builtin");
const std = @import("std");
const assert = std.debug.assert;
const maxInt = std.math.maxInt;

const limine = @import("limine.zig");

const log = @import("log.zig");
const logger = log.Logger{ .name = "memory" };

const Lock = @import("util.zig").Lock;

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

// MEMORY DIRECTORY

pub const Region = struct {
    ptr: [*][page_size]u8,
    // per-region locking for responsiveness
    // gives cores more chances to get a lock
    lock: Lock = .{},
    set: UsedSet,
};

comptime {
    // let's keep things small.
    assert(@sizeOf(Region) <= 48);
}

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
        const addr = @intFromPtr(entry.ptr) +| limine.hhdm.response.offset;
        entry.ptr = @ptrFromInt(addr);

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
            .ptr = @ptrCast(entry.ptr),
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

// do we wipe pages on allocation?
// TODO: compilation option for zeroing
const zero = false;

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
inline fn findBlockRegion(block: [][page_size]u8) ?*Region {
    const addr = @intFromPtr(block.ptr);
    for (0..regions.len) |i| {
        const region = &regions[i];

        region.lock.lockShared();
        defer region.lock.unlockShared();

        if (region.set.used < block.len) continue;

        const start = @intFromPtr(region.ptr);
        const end = start + (region.set.len * page_size);

        if (start <= addr and addr < end)
            return region;
    }

    return null;
}

// ALLOCATION

pub fn allocBlockInRegion(region: *Region, n: usize) ?[*][page_size]u8 {
    region.lock.lock();
    defer region.lock.unlock();

    if (@call(
        .always_inline,
        UsedSet.claimRange,
        .{ &region.set, n },
    )) |index| {
        const ptr = region.ptr + index;
        if (zero) for (0..n) |i|
            std.crypto.secureZero(u8, ptr[i]);

        return ptr;
    } else return null;
}

pub fn allocBlock(n: usize) ?[*][page_size]u8 {
    for (regions) |*region| {
        const block = @call(
            .always_inline,
            allocBlockInRegion,
            .{ region, n },
        );

        if (block) |ptr| return ptr;
    }

    return null;
}

// REALLOCATION / RESIZING

pub fn resizeBlockInRegion(
    region: *Region,
    block: [][page_size]u8,
    new_size: usize,
    comptime may_realloc: bool,
) ?[][page_size]u8 {
    assert(@intFromPtr(block.ptr) >= @intFromPtr(region.ptr));

    if (block.len >= new_size) return block[0..new_size];

    region.lock.lock();
    defer region.lock.unlock();

    const start = block.ptr - region.ptr;
    const new_start = @call(
        .always_inline,
        UsedSet.resizeRange,
        .{ &region.set, start, block.len, new_size, may_realloc },
    ) orelse return null;

    if (may_realloc and new_start != start) {
        const new_block = region.ptr + new_start;
        @memcpy(new_block[0..block.len], block);
        return new_block[0..new_size];
    }

    return block.ptr[0..new_size];
}

pub fn resizeBlock(block: [][page_size]u8, new_size: usize, comptime may_realloc: bool) ?[][page_size]u8 {
    if (block.len == new_size) return block;
    const region = findBlockRegion(block) orelse return null;
    return @call(.always_inline, resizeBlockInRegion, .{ region, block, new_size, may_realloc });
}

// DEALLOCATION

pub fn freeBlockInRegion(region: *Region, block: [][page_size]u8) void {
    assert(@intFromPtr(block.ptr) >= @intFromPtr(region.ptr));
    region.lock.lock();
    defer region.lock.unlock();

    @call(.always_inline, UsedSet.unclaimRange, .{ &region.set, block.ptr - region.ptr, block.len });
}

pub fn freeBlock(block: [][page_size]u8) bool {
    const region = findBlockRegion(block) orelse return false;
    @call(.always_inline, freeBlockInRegion, .{ region, block });
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

    fn alloc(_: *anyopaque, n: usize, _: Alignment, ret_addr: usize) ?[*]u8 {
        _ = ret_addr;

        assert(n > 0);
        if (n > maxInt(usize) - (page_size - 1)) return null;
        const block = allocBlock(pagesNeeded(n));
        return @ptrCast(block orelse return null);
    }

    inline fn resizeInner(buf: []u8, new_size: usize, comptime may_realloc: bool) ?[*]u8 {
        const old_len = pagesNeeded(buf.len);
        const new_len = pagesNeeded(new_size);
        if (old_len >= new_len) return buf.ptr;

        const ptr: [*][page_size]u8 = @ptrCast(buf.ptr);
        const block = @call(.always_inline, resizeBlock, .{ ptr[0..old_len], new_len, may_realloc });
        return @ptrCast(block orelse return null);
    }

    fn resize(
        _: *anyopaque,
        buf: []u8,
        _: Alignment,
        new_size: usize,
        ret_addr: usize,
    ) bool {
        _ = ret_addr;

        return resizeInner(buf, new_size, false) != null;
    }

    fn remap(
        _: *anyopaque,
        buf: []u8,
        _: Alignment,
        new_size: usize,
        ret_addr: usize,
    ) ?[*]u8 {
        _ = ret_addr;

        return resizeInner(buf, new_size, true);
    }

    fn free(_: *anyopaque, slice: []u8, _: Alignment, ret_addr: usize) void {
        _ = ret_addr;

        const ptr: [*][page_size]u8 = @ptrCast(slice.ptr);
        const pages = pagesNeeded(slice.len);
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
