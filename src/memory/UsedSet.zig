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

//pub const bits = @typeInfo(usize).int.bits;
//pub const usize_bytes = usize_bits / 8;
//const ShiftT = std.math.Log2Int(usize);
//const shiftv = std.math.log2_int(usize, bits);
//const set = maxInt(usize);

const Self = @This();

comptime {
    // let's keep things small.
    assert(@sizeOf(Self) <= 32);
}

pub inline fn allocate(allocator: std.mem.Allocator, size: usize) !Self {
    return .{ .ptr = (try allocator.alloc(u64, (size + 63) / 64)).ptr, .len = size };
}

// OPERATION IMPLEMENTATIONS

// unroll thresholds
const word_threshold = (4 * 16) - 1;
const dword_threshold = (4 * 32) - 1;
const qword_threshold = (4 * 64) - 1;

const Operation = enum { read, unset, set };

// regular bit operator; uses a whole function to DRY out the code
inline fn operation(self: *Self, offset: usize, comptime op: Operation) usize {
    const int = offset / 64;
    const shift: u6 = @truncate(offset);
    const bit = @as(u64, 1) << shift;

    const res = if (op != .set) (self.ptr[int] >> shift) & 1 else 0;

    if (op == .set) {
        self.ptr[int] |= bit;
    } else if (op == .unset) {
        self.ptr[int] &= ~bit;
    }

    return res;
}

// perf: align to an int and do integer-based iteration (sums in-use bits with popCount, or uses memset)
// this is called only by operations, which uses thresholds to decide when to use this over bit iteration
inline fn operationsFast(comptime T: type, self: *Self, start: usize, n: usize, comptime op: Operation) usize {
    const bits = switch (T) {
        u8, u16, u32, u64 => @typeInfo(T).int.bits,
        else => @compileError("invalid operationsFast type (u8, u16, u32, u64 allowed)"),
    };

    var res: usize = 0;

    // modify full ints at a time
    const end = start + n;
    const ints_end = end / bits;
    const ints_start = (start + (bits - 1)) / bits;

    var bitset: [*]T = @ptrCast(self.ptr);

    switch (op) {
        .set => @memset(bitset[ints_start..ints_end], maxInt(T)),
        .unset => for (ints_start..ints_end) |i| {
            res += @popCount(bitset[i]);
            bitset[i] = 0;
        },
        .read => for (ints_start..ints_end) |i| {
            res += @popCount(bitset[i]);
        },
    }

    // modify bits at the start
    for (start..ints_start * bits) |i|
        res += self.operation(i, op);

    // modify bits at the end
    for (ints_end * bits..end) |i|
        res += self.operation(i, op);

    return res;
}

// wrapper around operationsFast and the bit iteration implementation
// only if we need to read does this return anything but void, otherwise modifies used counter
fn operations(self: *Self, start: usize, n: usize, comptime op: Operation) if (op == .read) usize else void {
    const in_use = if (n < word_threshold) slow: {
        // op bits individually
        var res: usize = 0;
        for (start..start + n) |i|
            res += self.operation(i, op);
        break :slow res;
    } else if (n < dword_threshold)
        operationsFast(u16, self, start, n, op)
    else if (n < qword_threshold)
        operationsFast(u32, self, start, n, op)
    else
        operationsFast(u64, self, start, n, op);

    switch (op) {
        .set => self.used += n,
        .unset => self.used -= in_use,
        .read => return in_use,
    }
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

pub fn resizeRange(self: *Self, start: usize, size: usize, new_size: usize, comptime may_move: bool) ?usize {
    assert(start + size < self.len);

    if (size == new_size) return start;

    // shrinkage is super fast
    if (new_size < size) {
        self.operations(start + new_size, size - new_size, .unset);
        return start;
    }

    // growth is a bit more difficult

    const end = start + size;
    const growth = new_size - size;
    // either we get lucky and just expand the range...
    if (end == self.tail and start + new_size <= self.len - self.tail) {
        self.operations(end, growth, .set);
        self.tail += growth;
        return start;
    } else if (self.operations(end, growth, .read) == 0) {
        self.operations(end, growth, .set);
        return start;
    }

    // ...or we have to move it.
    if (!may_move) return null;
    return self.reallocRange(start, size, new_size);
}

pub inline fn reallocRange(self: *Self, start: usize, size: usize, new_size: usize) ?usize {
    const new_start = self.claimRange(new_size) orelse return null;
    self.unclaimRange(start, size);
    return new_start;
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
