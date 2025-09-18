//! The random number generator system.
//!
//! Each CPU gets its own ChaCha8 CSPRNG generator, and an entropy buffer.
//! Additionally, there is a global entropy pool backed by a SHA-3-based hash.
//!
//! When the entropy buffer is filled, or when cycleAllEntropy is called,
//! the entire buffer will be mixed into the global entropy pool. The pool is
//! then used to provide entropy to the generator. This way, we can gather and
//! spread entropy across every CPU, avoiding unnecessary writes and locking.

const std = @import("std");
const smp = @import("smp.zig");
const clock = @import("clock.zig");
const limine = @import("limine.zig");

const ChaCha = std.Random.ChaCha;
const Lock = @import("utils").lock.SpinLock;
const allocator = @import("memory.zig").allocator;
const TurboShake256 = std.crypto.hash.sha3.TurboShake256(null);

// STRUCTURES

const Entropy = struct {
    buffer: *[256]u8,
    index: u8 = 0,
    dumped: bool = false,

    pub fn add(self: *Entropy, value: anytype) void {
        const bytes: []const u8 =
            if (@typeInfo(@TypeOf(value)) == .pointer)
                std.mem.asBytes(value)[0..]
            else
                &std.mem.toBytes(value);

        for (0..bytes.len) |i| {
            self.buffer[self.index] = bytes[i];
            // wrap back to start at the end
            self.index +%= 1;

            if (self.dumped) {
                // will be set if cycleAllEntropy was called
                // avoid dumping the same entropy twice
                self.dumped = false;
                continue;
            }

            if (self.index == 0) {
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
    generator: ChaCha,

    pub fn cycleEntropy(self: *State, all: bool) void {
        // unless told otherwise, we should only mix
        // the newer bytes into the global entropy pool
        const end = if (all) 255 else self.entropy.index;
        entropy.update(self.entropy.buffer[0 .. end + 1]);
        // use the pool to give entropy to the generator
        var data: [64]u8 = undefined;
        entropy.squeeze(data[0..]);
        self.generator.addEntropy(data[0..]);
        // prevent double-dump in Entropy.add
        if (!all) self.entropy.dumped = true;
        asm volatile ("" ::: .{ .memory = true });
        // back to start of the buffer
        self.entropy.index = 0;
    }
};

const States = smp.LocalStorage(State);

var states: States = undefined;
var entropy = TurboShake256.init(.{});
var lock = Lock{};

// INITIALIZATION

pub fn init() void {
    // 16MiB minimum memory requirement, should never OOM
    states = States.init() catch unreachable;
    for (states.objects) |*state|
        state.* = .{
            .entropy = .{
                // 16MiB minimum memory requirement, should never OOM
                .buffer = @ptrCast(allocator.alloc(u8, 256) catch unreachable),
            },
            .generator = .init(makeSeed()),
        };
}

fn makeSeed() [32]u8 {
    var seed: [32]u8 = undefined;
    // delay will vary a bit in time spent
    for (0..32) |i| {
        seed[i] = @truncate(clock.counter());
        @import("util.zig").delay();
    }
    return seed;
}

// ADDING ENTROPY

pub fn addEntropy(value: anytype) void {
    const state = states.get();
    state.entropy.add(value);
}

/// Add entropy from the clock value.
/// Call this as much as possible.
pub fn clockEntropy() void {
    // upper bits won't provide much unique data
    addEntropy(@as(u32, @truncate(clock.counter())));
}

pub fn cycleAllEntropy() void {
    lock.lock();
    for (states.objects) |*state|
        state.cycleEntropy(false);
    lock.unlock();
}

// GENERATING VALUES

fn fill(_: *anyopaque, buf: []u8) void {
    states.get().generator.fill(buf);
}

pub fn random() std.Random {
    return .{
        .ptr = undefined,
        .fillFn = fill,
    };
}
