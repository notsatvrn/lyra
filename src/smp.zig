const std = @import("std");
const limine = @import("limine.zig");
const gdt = @import("gdt.zig");
const isr = @import("int/isr.zig");
const rng = @import("rng.zig");

const logger = @import("log.zig").Logger{ .name = "smp" };

// INITIALIZATION

pub var launched = false;

pub fn launch(comptime entry: fn () noreturn) noreturn {
    const cpus = limine.cpus.response;
    const cpu0 = cpus.cpus[0];

    std.debug.assert(cpu0.lapic_id == cpus.bsp_lapic_id);
    gdt.update(cpus.count) catch unreachable;
    isr.newStacks(cpus.count) catch unreachable;

    const wrap = struct {
        pub fn wrapped(cpu: *const limine.Cpu) callconv(.c) noreturn {
            gdt.load(cpu.index);
            isr.storeStack();
            entry();
        }
    };

    launched = true;
    for (1..cpus.count) |i| {
        const cpu = cpus.cpus[i];
        cpu.index = i;
        cpu.jump(wrap.wrapped);
        rng.clockEntropy();
    }

    cpu0.index = 0;
    gdt.load(0);
    entry();
}

// HELPER FUNCTIONS

/// Use the GDT to identify the current CPU.
pub const getCpu = gdt.str;

pub inline fn info() *const limine.Cpu {
    return limine.cpus.response.cpus[getCpu()];
}

pub inline fn count() usize {
    return limine.cpus.response.count;
}

// TODO: add things like runNTimes, runOnCpu, etc
fn funcReturnType(func: anytype) type {
    const t_info = @typeInfo(@TypeOf(func));
    const func_t = func_t: switch (t_info) {
        .@"fn" => |v| v,
        .pointer => |v| continue :func_t @typeInfo(v.child),
        else => @compileError("non-function passed to call wrapper"),
    };
    const ReturnT = func_t.return_type orelse void;
    return if (ReturnT != void) ?ReturnT else void;
}

pub inline fn runOnce(func: anytype) funcReturnType(func) {
    if (getCpu() == 0) return (func)();
    if (funcReturnType(func) != void) return null;
}

pub const Barrier = struct {
    current: usize = 0,
    expected: usize = 0,

    pub fn init(expected: usize) Barrier {
        return .{ .expected = if (expected > 0) expected else count() };
    }

    pub fn wait(self: *Barrier) void {
        const previous = @atomicRmw(usize, &self.current, .Add, 1, .monotonic);
        if (previous == self.expected - 1) return;

        while (@atomicLoad(usize, &self.current, .monotonic) != self.expected)
            std.atomic.spinLoopHint();
    }
};

// CPU-LOCAL STORAGE

const allocator = @import("memory.zig").allocator;

pub fn LockingStorage(comptime T: type) type {
    return struct {
        const Lock = @import("utils").lock.SpinLock;

        objects: []Entry,

        const Entry = struct {
            lock: Lock = .{},
            dirty: bool = false,
            value: T,
        };

        const Self = @This();

        // INIT / DEINIT

        pub fn init() !Self {
            const n = limine.cpus.response.count;
            return .{ .objects = try allocator.alloc(Entry, n) };
        }

        pub inline fn deinit(self: Self) void {
            allocator.free(self.objects);
        }

        // LOCKING

        pub fn lockCpu(self: *Self, cpu: usize) *T {
            const object = &self.objects[cpu];
            object.lock.lock();
            if (cpu != getCpu()) object.dirty = true;
            return &object.value;
        }

        pub fn lock(self: *Self) *T {
            const object = &self.objects[getCpu()];
            object.lock.lock();
            return &object.value;
        }

        pub inline fn isDirty(_: Self, object: *T) bool {
            const entry: *Entry = @fieldParentPtr("value", object);
            return entry.dirty;
        }

        // UNLOCKING

        pub inline fn unlockCpu(self: *Self, cpu: usize) void {
            self.objects[cpu].lock.unlock();
        }

        pub inline fn unlock(self: *Self) void {
            self.unlockCpu(getCpu());
        }
    };
}
