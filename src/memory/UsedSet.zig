//! An optimized "used" set implementation for allocators.

const std = @import("std");
const assert = std.debug.assert;

ptr: [*]u64,
len: usize,
used: usize = 0,
// perf: use a "tail" for finding available bits
// marks the point where further bits will *definitely* be available
// it's not always worth looking for available bits before the tail,
// but falling back if needed just requires a simple check
tail: usize = 0,

const Self = @This();

comptime {
    // let's keep things small.
    assert(@sizeOf(Self) <= 32);
}

pub inline fn allocate(allocator: std.mem.Allocator, size: usize) !Self {
    return .{ .ptr = (try allocator.alloc(u64, (size + 63) / 64)).ptr, .len = size };
}

// OPERATION IMPLEMENTATIONS

const Operation = enum { read, unset, set };

inline fn mkmask(n: usize, offset: usize) u64 {
    return ((@as(u64, 1) << @truncate(n)) - 1) << @truncate(offset);
}

inline fn applyMask(self: *Self, int: usize, mask: u64, comptime op: Operation) usize {
    const res = if (op != .set) @popCount(self.ptr[int] & mask) else 0;

    if (op == .set)
        self.ptr[int] |= mask
    else if (op == .unset)
        self.ptr[int] &= ~mask;

    return res;
}

inline fn opret(self: *Self, n: usize, res: usize, comptime op: Operation) if (op == .read) usize else void {
    switch (op) {
        .set => self.used += n,
        .unset => self.used -= res,
        .read => return res,
    }
}

// optimized bitset operation function using whole integers, masking, and intrinsics for quick manipulation
fn operation(self: *Self, start: usize, n: usize, comptime op: Operation) if (op == .read) usize else void {
    // fast path: only one page to mark
    // we know one bit will always fit into only one integer
    // skip unneeded math, don't use @popCount for no reason
    if (n == 1) {
        const int = start / 64;
        const shift: u6 = @truncate(start);
        const res = if (op != .set) (self.ptr[int] >> shift) & 1 else 0;

        if (op == .set)
            self.ptr[int] |= @as(u64, 1) << shift
        else if (op == .unset)
            self.ptr[int] -= @as(u64, 1) << shift; // when only one bit is set, we can do rhs - lhs instead of rhs & ~lhs

        return self.opret(1, res, op);
    }

    var res: usize = 0;

    // modify bits at the start
    const ints_start = (start + 63) / 64;
    const start_bits = @min(n, (ints_start * 64) - start);
    if (start_bits > 0) {
        const start_int = start / 64;
        const start_mask = mkmask(start_bits, start - (start_int * 64));
        res += self.applyMask(start_int, start_mask, op);
        // only needed to modify bits of one integer
        if (start_bits == n) return self.opret(n, res, op);
    }

    // modify bits at the end
    const end = start + n;
    const ints_end = end / 64;
    const end_bits = end % 64;
    if (end_bits > 0) {
        const end_mask = mkmask(end_bits, 0);
        res += self.applyMask(ints_end, end_mask, op);
        // only needed to modify bits of two integers
        if (ints_end <= ints_start) return self.opret(n, res, op);
    }

    // modify integers in between
    switch (op) {
        .set => @memset(self.ptr[ints_start..ints_end], ~@as(u64, 0)),
        .unset => for (ints_start..ints_end) |i| {
            res += @popCount(self.ptr[i]);
            self.ptr[i] = 0;
        },
        .read => for (ints_start..ints_end) |i| {
            res += @popCount(self.ptr[i]);
        },
    }

    return self.opret(n, res, op);
}

// CLAIM RANGE (ALLOCATION)

// allocate from the tail (fast)
pub fn claimRangeFast(self: *Self, n: usize) ?usize {
    if (self.len - self.tail < n) return null;

    defer self.tail += n;
    self.operation(self.tail, n, .set);
    return self.tail;
}

// allocate from the start
pub fn claimRange(self: *Self, n: usize) ?usize {
    if (self.len - self.used < n) return null;

    const ints = (self.len + 63) / 64;
    var bit_rem = self.len;

    // fast path: only one page
    if (n == 1) {
        for (0..ints) |int| {
            const bits = self.ptr[int];

            if (bit_rem < 64) {
                @branchHint(.unlikely);
                const shift: u6 = @truncate(bit_rem);
                const mask = (@as(u64, 1) << shift) - 1;
                // last int, just return, region is full
                if (bits & mask == mask) return null;
            } else if (bits == ~@as(u64, 0)) continue;

            // ctz of ~bits = pages until first unused page
            self.operation((int * 64) + @ctz(~bits), 1, .set);
        }

        return null;
    }

    var start: usize = 0;
    var rem: usize = n;

    for_ints: for (0..ints) |int| {
        var bits = self.ptr[int];
        var len = @min(bit_rem, 64);
        bit_rem -= len;

        const end = start + len;
        while (start < end) {
            var zeroes = @min(@ctz(bits), len);
            rem -|= zeroes;
            if (rem == 0) {
                self.operation(start, n, .set);
                return start;
            } else if (zeroes == len) {
                continue :for_ints;
            }

            // skip used pages
            const used_bits = ~(bits >> @truncate(zeroes));
            zeroes += @min(@ctz(used_bits), len - zeroes);
            bits >>= @truncate(zeroes);

            // reset for next iter
            start += zeroes;
            len -= zeroes;
            rem = n;
        }
    }

    return null;
}

// RESIZE RANGE (REALLOCATION)

pub fn resizeRange(self: *Self, start: usize, size: usize, new_size: usize) bool {
    assert(start + size < self.len);

    if (size == new_size) return true;

    // shrinkage is super fast
    if (new_size < size) {
        self.operation(start + new_size, size - new_size, .unset);
        return true;
    }

    // growth is a bit more difficult

    const end = start + size;
    const growth = new_size - size;

    if (end == self.tail and start + new_size <= self.len - self.tail) {
        self.operation(end, growth, .set);
        self.tail += growth;
        return true;
    } else if (self.operation(end, growth, .read) == 0) {
        self.operation(end, growth, .set);
        return true;
    } else return false;
}

// UNCLAIM RANGE (DEALLOCATION)

pub fn unclaimRange(self: *Self, start: usize, n: usize) void {
    assert(start + n < self.len);

    // unset bits and reclaim in-use
    self.operation(start, n, .unset);

    // if this isn't tail range, return
    if (start + n != self.tail) return;

    // backtrack if range is from tail
    var tail = start / 64;
    while (tail >= 0) : (tail -= 1) {
        const int = self.ptr[tail];
        if (int != 0) {
            self.tail = ((tail + 1) * 64) - @clz(int);
            break;
        }
    }
}
