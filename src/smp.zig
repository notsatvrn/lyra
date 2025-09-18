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
    // 16MiB minimum memory requirement, should never OOM
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

// THREAD-LOCAL STORAGE

const allocator = @import("memory.zig").allocator;

pub fn LocalStorage(comptime T: type) type {
    return struct {
        objects: []T,

        const Self = @This();

        // INIT / DEINIT

        pub fn init() !Self {
            const n = limine.cpus.response.count;
            return .{ .objects = try allocator.alloc(T, n) };
        }

        pub inline fn deinit(self: Self) void {
            allocator.free(self.objects);
        }

        // GET

        pub inline fn get(self: *Self) *T {
            return &self.objects[getCpu()];
        }
    };
}

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

        pub inline fn isDirty(object: *T) bool {
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
