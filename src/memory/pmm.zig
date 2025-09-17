//! The physical memory management system.
//!
//! All we do here is split up memory into pages and track which ones are
//! in active use. No permissions or other garbage here, just the basics.
//!
//! Despite that, the implementation is far from simple. I've tried my best
//! to provide ample documentation but I'm happy to add more if needed.

const std = @import("std");
const assert = std.debug.assert;

const limine = @import("../limine.zig");
const logger = @import("../log.zig").Logger{ .name = "pmm" };

const memory = @import("../memory.zig");
const PageSize = memory.PageSize;
const min_page_size = memory.min_page_size;
const pagesNeeded = memory.pagesNeeded;

// REGION STRUCTURE

pub const Region = struct {
    const UsedSet = @import("UsedSet.zig");
    const Lock = @import("utils").lock.SpinSharedLock;

    ptr: [*]u8,
    set: UsedSet,
    lock: Lock = .{},

    const Self = @This();

    // OPERATIONS

    pub fn map(self: *Self, size: PageSize, len: usize, comptime fast: bool) ?[*]u8 {
        self.lock.lock();
        defer self.lock.unlock();
        _ = size; // TODO: hugepages

        const index = (if (fast)
            self.set.claimRangeFast(len)
        else
            self.set.claimRange(len)) orelse return null;

        return @ptrCast(self.ptr + (index * min_page_size));
    }

    pub fn remap(self: *Self, ptr: [*]u8, size: PageSize, len: usize, new_len: usize, may_move: bool) ?[*]u8 {
        assert(@intFromPtr(ptr) >= @intFromPtr(self.ptr));

        if (new_len <= len) return ptr;

        self.lock.lock();
        defer self.lock.unlock();
        _ = size; // TODO: hugepages

        const start = (ptr - self.ptr) / min_page_size;
        const resized = self.set.resizeRange(start, len, new_len);
        if (resized) return ptr;
        if (!may_move) return null;

        self.set.unclaimRange(start, len);
        const new_start = self.set.claimRange(new_len) orelse return null;
        const new_block = self.ptr + (new_start * min_page_size);
        @memcpy(new_block[0 .. len * min_page_size], ptr); // TODO: hugepages
        return @ptrCast(new_block);
    }

    pub fn unmap(self: *Self, ptr: [*]u8, size: PageSize, len: usize) void {
        assert(@intFromPtr(ptr) >= @intFromPtr(self.ptr));

        self.lock.lock();
        defer self.lock.unlock();
        _ = size; // TODO: hugepages

        self.set.unclaimRange((ptr - self.ptr) / min_page_size, len);
    }
};

// MEMORY DIRECTORY

var regions: []Region = undefined;
var total: usize = 0;

pub fn init() void {
    var usable: usize = 0;

    var largest: []u8 = "";
    var bitsets_size: usize = 0;

    logger.debug("memory regions: ", .{});
    for (0..limine.mmap.response.count) |i| {
        const entry = limine.mmap.response.entries[i];
        if (entry.type != .usable) continue;

        const addr = @intFromPtr(entry.ptr);
        const pages = entry.len >> PageSize.small.shift();
        logger.debug("- 0x{x:0>16}, {} pages", .{ addr, pages });
        // bitset implementation requires 64-bit alignment
        bitsets_size += (pages + 63) / 64;
        // put the address in Limine's higher-half direct map
        // absolutely required, if we don't do this writes cause crashes
        entry.ptr = limine.convertPointer(entry.ptr);
        // find the largest region and put region info at the start
        if (entry.len > largest.len) largest = entry.ptr[0..entry.len];

        usable += 1;
    }

    // make sure bitset space still has 64-bit alignment
    const regions_bytes = (usable * @sizeOf(Region) + 7) & ~@as(usize, 7);
    const info_space = regions_bytes + bitsets_size * 8;
    const info_pages = pagesNeeded(info_space, .small);
    if (info_pages * min_page_size > largest.len)
        logger.panic("not enough memory for region info", .{});

    regions = @as([*]Region, @ptrCast(@alignCast(largest.ptr)))[0..usable];
    var b: [*]u64 = @ptrCast(@alignCast(largest.ptr + regions_bytes));
    std.crypto.secureZero(u64, b[0..bitsets_size]);

    var s: usize = 0;
    for (0..limine.mmap.response.count) |i| {
        const entry = limine.mmap.response.entries[i];
        if (entry.type != .usable) continue;

        const pages = entry.len >> PageSize.small.shift();
        var region = Region{
            .ptr = @ptrCast(@alignCast(entry.ptr)),
            .set = .{ .ptr = b, .len = pages },
        };

        // mark pages holding region info as used
        if (largest.ptr == entry.ptr) {
            region.set.used += info_pages;
            region.set.tail = info_pages;
            for (0..info_pages) |j| {
                const int = j / 64;
                const offset: u6 = @truncate(j);
                b[int] |= @as(u64, 1) << offset;
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
    // let's make out-of-memory scenarios impossible for early boot stuff
    if (total < 4096) logger.panic("less than 16MiB memory available!", .{});
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
inline fn findRegion(ptr: [*]u8) ?*Region {
    const addr = @intFromPtr(ptr);
    for (0..regions.len) |i| {
        const region = &regions[i];

        region.lock.lockShared();
        defer region.lock.unlockShared();

        const start = @intFromPtr(region.ptr);
        const end = start + (region.set.len * min_page_size);

        if (addr >= start and addr < end)
            return region;
    }

    return null;
}

// OPERATIONS

pub fn map(size: PageSize, len: usize) ?[*]u8 {
    // try all regions until we can allocate fast, then slow only if needed
    for (regions) |*region| if (region.map(size, len, true)) |ptr| return ptr;
    for (regions) |*region| if (region.map(size, len, false)) |ptr| return ptr;

    return null;
}

pub fn remap(ptr: [*]u8, size: PageSize, len: usize, new_len: usize, may_move: bool) ?[*]u8 {
    if (new_len <= len) return ptr;
    const region = findRegion(ptr) orelse return null;
    return region.remap(ptr, size, len, new_len, may_move);
}

pub fn unmap(ptr: [*]u8, size: PageSize, len: usize) bool {
    const region = findRegion(ptr) orelse return false;
    region.unmap(ptr, size, len);
    return true;
}
