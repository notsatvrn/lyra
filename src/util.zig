const std = @import("std");

// LOCKING MECHANISMS

pub const SpinLock = struct {
    inner: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    pub fn lock(self: *SpinLock) void {
        while (self.inner.cmpxchgWeak(0, 1, .acquire, .monotonic) != null)
            std.atomic.spinLoopHint();
    }

    pub fn tryLock(self: *SpinLock) bool {
        return self.inner.cmpxchgWeak(0, 1, .acquire, .monotonic) == null;
    }

    pub fn unlock(self: *SpinLock) void {
        self.inner.store(0, .release);
    }
};

pub const SpinRwLock = struct {
    inner: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    pub fn lock(self: *SpinRwLock) void {
        while (self.inner.cmpxchgWeak(0, 0x80000000, .acquire, .monotonic) != null)
            std.atomic.spinLoopHint();
    }

    pub fn lockShared(self: *SpinRwLock) void {
        while (true) {
            const state = self.inner.load(.unordered);
            if (state & 0x80000000 == 0 and
                self.inner.cmpxchgWeak(state, state + 1, .acquire, .monotonic) == null)
                return;

            std.atomic.spinLoopHint();
        }
    }

    pub fn unlock(self: *SpinRwLock) void {
        self.inner.store(0, .release);
    }

    pub fn unlockShared(self: *SpinRwLock) void {
        _ = self.inner.fetchSub(1, .release);
    }
};

pub const Lock = SpinRwLock;
