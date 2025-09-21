//! The random number generator system.
//!
//! Each CPU gets its own ChaCha8 CSPRNG generator, and an entropy buffer.
//! Additionally, there is a global entropy pool using 512-bit Blake2b hashing.
//!
//! When the entropy buffer is filled, or when cycleAllEntropy is called,
//! the entire buffer will be mixed into the global entropy pool. The pool is
//! then used to provide entropy to the generator. This way, we can gather and
//! spread entropy across every CPU, avoiding unnecessary writes and locking.
//!
//! The per-cpu entropy buffers are lock-free by use of atomics.

const std = @import("std");
const smp = @import("smp.zig");
const clock = @import("clock.zig");

const Atomic = std.atomic.Value;
const ChaCha = std.Random.ChaCha;
const Lock = @import("utils").lock.SpinLock;
const allocator = @import("memory.zig").allocator;
const Blake2b = std.crypto.hash.blake2.Blake2b512;

// STRUCTURES

const Entropy = struct {
    buffer: *[256]u8,
    index: Atomic(u8) = .init(0),

    pub fn add(self: *Entropy, value: anytype) void {
        const info = @typeInfo(@TypeOf(value));
        self.addBytes(switch (info) {
            .pointer => @ptrCast(value),
            else => &std.mem.toBytes(value),
        });
    }

    pub fn addBytes(self: *Entropy, bytes: []const u8) void {
        for (0..bytes.len) |i| {
            const index = self.index.fetchAdd(1, .seq_cst);
            self.buffer[index] = bytes[i];

            if (index == 255) {
                // only happens every 256 bytes
                @branchHint(.unlikely);
                const state: *State = @fieldParentPtr("entropy", self);
                lock.lock();
                state.cycleEntropy(true);
                lock.unlock();
            }
        }
    }
};

const State = struct {
    entropy: Entropy,
    generator: ChaCha = .{
        .state = undefined,
        .offset = init_offset,
    },

    // offset will never actually get this big
    const init_offset = std.math.maxInt(usize);

    pub fn cycleEntropy(self: *State, all: bool) void {
        // unless told otherwise, we should only mix
        // the newer bytes into the global entropy pool
        const index = self.entropy.index.rmw(.Xchg, 0, .seq_cst);
        const end = if (all) 256 else @as(usize, index) + 1;
        entropy.update(self.entropy.buffer[0..end]);
        // make sure generator is ready before continuing
        if (self.generator.offset == init_offset) return;
        // use the pool to give entropy to the generator
        var data: [64]u8 = undefined;
        entropy.final(data[0..]);
        self.generator.addEntropy(data[0..]);
    }
};

var states: []State = undefined;
var entropy = Blake2b.init(.{});
var lock = Lock{};

// INITIALIZATION

const logger = @import("log.zig").Logger{ .name = "rng" };

pub fn initBuffers() void {
    states = allocator.alloc(State, smp.count()) catch unreachable;
    for (states) |*state| {
        const buffer = allocator.create([256]u8) catch unreachable;
        state.entropy = .{ .buffer = buffer };
    }
    clockEntropy();
    logger.info("{} entropy buffers ready", .{smp.count()});
}

pub fn initGenerator() void {
    const state = &states[smp.getCpu()];
    var seed: [32]u8 = undefined;
    for (0..32) |i| {
        seed[i] = @truncate(clock.counter());
        // delay time will vary a lot (1-4 us)
        // should be adequate for a seed
        @import("util.zig").delay();
        // also add to the entropy
        state.entropy.add(seed[i]);
    }
    state.generator = .init(seed);
    logger.info("generator ready", .{});
}

// ADDING ENTROPY

pub fn addEntropy(value: anytype) void {
    states[smp.getCpu()].entropy.add(value);
}

pub fn addEntropyBytes(bytes: []const u8) void {
    states[smp.getCpu()].entropy.addBytes(bytes);
}

/// Add entropy from the clock value.
/// Call this as much as possible.
pub fn clockEntropy() void {
    // upper bits won't provide much unique data
    addEntropy(@as(u32, @truncate(clock.counter())));
}

pub fn cycleAllEntropy() void {
    lock.lock();
    for (states) |*state| state.cycleEntropy(false);
    lock.unlock();
}

// GENERATING VALUES

fn fill(_: *anyopaque, buf: []u8) void {
    states[smp.getCpu()].generator.fill(buf);
}

pub fn random() std.Random {
    return .{
        .ptr = undefined,
        .fillFn = fill,
    };
}
