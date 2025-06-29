const std = @import("std");

// SPIN-LOCKING MECHANISMS

pub const SpinLock = packed struct {
    inner: u8 = 0,

    pub fn lock(self: *SpinLock) void {
        while (@cmpxchgWeak(u8, &self.inner, 0, 1, .acquire, .monotonic) != null)
            std.atomic.spinLoopHint();
    }

    pub fn tryLock(self: *SpinLock) bool {
        return @cmpxchgWeak(u8, &self.inner, 0, 1, .acquire, .monotonic) == null;
    }

    pub fn unlock(self: *SpinLock) void {
        @atomicStore(u8, &self.inner, 0, .release);
    }
};

pub const SpinSharedLock = packed struct {
    inner: u32 = 0,

    pub fn lock(self: *SpinSharedLock) void {
        return self.lockInner(0);
    }

    /// Upgrades a shared lock to an exclusive one.
    pub fn relock(self: *SpinSharedLock) void {
        return self.lockInner(1);
    }

    inline fn lockInner(self: *SpinSharedLock, allowed: u32) void {
        while (@cmpxchgWeak(u32, &self.inner, allowed, 0x80000000, .acquire, .monotonic) != null)
            std.atomic.spinLoopHint();
    }

    pub fn lockShared(self: *SpinSharedLock) void {
        while (true) {
            const state = @atomicLoad(u32, &self.inner, .unordered);
            if (state & 0x80000000 == 0 and
                @cmpxchgWeak(u32, &self.inner, state, state + 1, .acquire, .monotonic) == null)
                return;

            std.atomic.spinLoopHint();
        }
    }

    pub fn unlock(self: *SpinSharedLock) void {
        @atomicStore(u32, &self.inner, 0, .release);
    }

    pub fn unlockShared(self: *SpinSharedLock) void {
        _ = @atomicRmw(u32, &self.inner, .Sub, 1, .release);
    }
};
