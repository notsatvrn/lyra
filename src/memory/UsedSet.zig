//! An optimized "used" set implementation for allocators.

const std = @import("std");
const assert = std.debug.assert;
const maxInt = std.math.maxInt;

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
    const current = self.ptr[int] & mask;
    const res = if (op != .set) @popCount(current) else 0;

    if (op == .set) {
        self.ptr[int] |= mask;
    } else if (op == .unset) {
        self.ptr[int] &= ~mask;
    }

    return res;
}

inline fn opret(self: *Self, n: usize, res: usize, comptime op: Operation) if (op == .read) usize else void {
    switch (op) {
        .set => self.used += n,
        .unset => self.used -= res,
        .read => return res,
    }
}

// wrapper around operationsFast and the bit iteration implementation
// only if we need to read does this return anything but void, otherwise modifies used counter
fn operations(self: *Self, start: usize, n: usize, comptime op: Operation) if (op == .read) usize else void {
    var res: usize = 0;
    const end = start + n;

    // modify bits at the start
    const ints_start = (start + 63) / 64;
    const start_int = start / 64;
    const start_bits = (ints_start * 64) - start;
    const start_mask = mkmask(start_bits, start - (start_int * 64));
    res += self.applyMask(start_int, start_mask, op);

    // only needed to modify bits of one integer
    if (end <= ints_start * 64) return self.opret(n, res, op);

    // modify bits at the end
    const ints_end = end / 64;
    const end_mask = mkmask(end % 64, 0);
    res += self.applyMask(ints_end, end_mask, op);

    // only needed to modify bits of two integers
    if (ints_end <= ints_start) return self.opret(n, res, op);

    // modify integers in between
    switch (op) {
        .set => @memset(self.ptr[ints_start..ints_end], maxInt(u64)),
        .unset => for (ints_start..ints_end) |i| {
            res += @popCount(self.ptr[i]);
            self.ptr[i] = 0;
        },
        .read => for (ints_start..ints_end) |i| {
            res += @popCount(self.ptr[i]);
        },
    }

    self.opret(n, res, op);
}

// CLAIM RANGE (ALLOCATION)

pub fn claimRange(self: *Self, n: usize) ?usize {
    if (self.len - self.used < n) return null;

    // allocate from the tail (fast)

    if (self.len - self.tail >= n) {
        defer self.tail += n;
        self.operations(self.tail, n, .set);
        return self.tail;
    }

    // allocate from the start

    const ints = (self.len + 63) / 64;
    var bit_rem = self.len;
    var start: usize = 0;
    var rem: usize = n;

    for (0..ints) |i| {
        const int = self.ptr[i];
        const not_int = ~int;

        const len = @min(bit_rem, 64);
        bit_rem -= len;

        if (int == 0) {
            rem -|= len;
            if (rem == 0) {
                self.operations(start, n, .set);
                return start;
            }

            continue;
        } else if (@popCount(not_int) < rem) {
            // num free pages < num needed pages

            // just add 64 here, partial ints
            // will make the loop end anyways
            start += 64;
            rem = n;
            continue;
        }

        for (@ctz(not_int)..len) |j| {
            rem -= 1;
            if ((int >> @truncate(j)) & 1 == 1) {
                start += n - rem;
                rem = n;
                continue;
            } else if (rem != 0)
                continue;

            self.operations(start, n, .set);
            return start;
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
        self.operations(start + new_size, size - new_size, .unset);
        return true;
    }

    // growth is a bit more difficult

    const end = start + size;
    const growth = new_size - size;

    if (end == self.tail and start + new_size <= self.len - self.tail) {
        self.operations(end, growth, .set);
        self.tail += growth;
        return true;
    } else if (self.operations(end, growth, .read) == 0) {
        self.operations(end, growth, .set);
        return true;
    } else return false;
}

// UNCLAIM RANGE (DEALLOCATION)

pub fn unclaimRange(self: *Self, start: usize, n: usize) void {
    assert(start + n < self.len);

    // unset bits and reclaim in-use
    self.operations(start, n, .unset);

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
