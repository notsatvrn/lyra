//! The physical memory management system.
//!
//! All we do here is split up memory into pages and track which ones are
//! in active use. No permissions or other garbage here, just the basics.
//!
//! Despite that, the implementation is far from simple. I've tried my best
//! to provide ample documentation but I'm happy to add more if needed.

const std = @import("std");
const assert = std.debug.assert;
const Alignment = std.mem.Alignment;

const limine = @import("../limine.zig");
const logger = @import("../log.zig").Logger{ .name = "pmm" };

const memory = @import("../memory.zig");
const PageSize = memory.PageSize;
const pagesNeeded = memory.pagesNeeded;

const min_page_size = memory.min_page_size;
const min_alignment = Alignment.fromByteUnits(min_page_size);

// REGION STRUCTURE

pub const Region = struct {
    const UsedSet = @import("UsedSet.zig");
    const Lock = @import("utils").lock.SpinSharedLock;

    ptr: [*]u8,
    set: UsedSet,
    lock: Lock = .{},

    const Self = @This();

    // OPERATIONS

    // Actual alignment for both the page size and provided custom alignment
    inline fn realAlignment(alignment: Alignment, size: PageSize) Alignment {
        const size_align: Alignment = @enumFromInt(size.shift());
        return alignment.max(size_align);
    }

    // Provided alignment must be the one returned from realAlignment. Used in map() and remap()
    fn mapInternal(self: *Self, alignment: Alignment, size: PageSize, len: usize) ?usize {
        if (alignment == min_alignment) {
            // fast path: no alignment requirement
            // skip some math and use unaligned claiming
            return self.set.claimRange(len);
        }

        const region_addr = @intFromPtr(self.ptr);
        const aligned_region_addr = alignment.forward(region_addr);
        const offset = (aligned_region_addr - region_addr) / min_page_size;
        if (offset > self.set.len) return null;

        const set_align = @as(usize, 1) << (@intFromEnum(alignment) - 12);

        var adjusted_len = len << (size.shift() - 12);
        if (offset + adjusted_len > self.set.len)
            adjusted_len -= offset + adjusted_len - self.set.len;

        return self.set.claimRangeAdvanced(offset, set_align, adjusted_len);
    }

    pub fn map(self: *Self, _alignment: Alignment, size: PageSize, len: usize) ?[*]u8 {
        self.lock.lock();
        defer self.lock.unlock();

        const alignment = realAlignment(_alignment, size);
        const index = self.mapInternal(alignment, size, len) orelse return null;
        return @ptrCast(self.ptr + index * min_page_size);
    }

    // Handles a few weird cases, such as the aligned pointer being before the start of the region.
    inline fn alignedIndexAndLen(self: Self, ptr: [*]u8, len: usize, alignment: Alignment) ?struct { usize, usize } {
        const aligned_addr = alignment.backward(@intFromPtr(ptr));
        const region_addr = @intFromPtr(self.ptr);
        var out: struct { usize, usize } = .{ 0, len };

        if (aligned_addr > region_addr) {
            // aligned address is after region start. set index
            out[0] = (aligned_addr - region_addr) / min_page_size;
            // index must be behind the end of the set
            if (out[0] >= self.set.len) return null;
        } else {
            // aligned address is before region start. decrease len
            out[1] -= ((region_addr - aligned_addr) / min_page_size);
        }

        // make index + len still fit in the set
        if (out[0] + out[1] > self.set.len)
            out[1] -= out[0] + out[1] - self.set.len;

        return out;
    }

    pub fn remap(self: *Self, ptr: [*]u8, _alignment: Alignment, size: PageSize, len: usize, new_len: usize, may_move: bool) ?[*]u8 {
        assert(@intFromPtr(ptr) >= @intFromPtr(self.ptr));

        if (new_len <= len) return ptr;

        self.lock.lock();
        defer self.lock.unlock();

        // try to simply resize the allocation

        const alignment = realAlignment(_alignment, size);
        const len_shift = size.shift() - 12;
        const sized_len = len << len_shift;
        const index_len = self.alignedIndexAndLen(ptr, sized_len, alignment) orelse return null;
        const index = index_len[0];
        const adjusted_len = index_len[1];
        const adjusted_new_len = (new_len << len_shift) - (sized_len - adjusted_len);

        if (self.set.resizeRange(index, adjusted_len, adjusted_new_len)) return ptr;
        if (!may_move) return null;

        // we have to move the allocation

        self.set.unclaimRange(index, adjusted_len);
        const new_index = self.mapInternal(alignment, size, new_len) orelse return null;
        const new_block = self.ptr + new_index * min_page_size;
        @memcpy(new_block[0 .. adjusted_len * min_page_size], ptr);
        return @ptrCast(new_block);
    }

    pub fn unmap(self: *Self, ptr: [*]u8, _alignment: Alignment, size: PageSize, len: usize) void {
        assert(@intFromPtr(ptr) >= @intFromPtr(self.ptr));

        self.lock.lock();
        defer self.lock.unlock();

        const alignment = realAlignment(_alignment, size);
        const len_shift = size.shift() - 12;
        const sized_len = len << len_shift;
        const index_len = self.alignedIndexAndLen(ptr, sized_len, alignment) orelse return;
        self.set.unclaimRange(index_len[0], index_len[1]);
    }
};

// MEMORY DIRECTORY

var regions: []Region = undefined;
var total: usize = 0;

pub fn init() void {
    var usable: usize = 0;

    var largest: []u8 = "";
    var bitsets_size: usize = 0;

    logger.info("memory regions: ", .{});
    for (0..limine.mmap.response.count) |i| {
        const entry = limine.mmap.response.entries[i];
        if (entry.type != .usable) continue;

        const addr = @intFromPtr(entry.ptr);
        const pages = entry.len >> PageSize.small.shift();
        logger.info("- 0x{X:0>16}, {} pages", .{ addr, pages });
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

    const minimum = pagesNeeded(128 * memory.MB, .small); // 128MiB required
    if (total < minimum) logger.panic("less than 128MiB memory available!", .{});

    logger.info("{}/{} KiB used", .{ used() * 4, total * 4 });
    memory.ready = true;
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

pub fn map(alignment: Alignment, size: PageSize, len: usize) ?[*]u8 {
    for (regions) |*region| if (region.map(alignment, size, len)) |ptr| return ptr;
    return null;
}

pub fn remap(ptr: [*]u8, alignment: Alignment, size: PageSize, len: usize, new_len: usize, may_move: bool) ?[*]u8 {
    if (new_len <= len) return ptr;
    const region = findRegion(ptr) orelse return null;
    return region.remap(ptr, alignment, size, len, new_len, may_move);
}

pub fn unmap(ptr: [*]u8, alignment: Alignment, size: PageSize, len: usize) bool {
    const region = findRegion(ptr) orelse return false;
    region.unmap(ptr, alignment, size, len);
    return true;
}
