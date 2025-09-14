const limine = @import("limine.zig");
const memory = @import("memory.zig");

const logger = @import("log.zig").Logger{ .name = "smp" };

// HELPER FUNCTIONS

const gdt = @import("gdt.zig");
const isr = @import("int/isr.zig");

pub fn init(comptime entry: fn () noreturn) noreturn {
    const cpus = limine.cpus.response;
    const cpu0 = cpus.cpus[0];

    // not sure if this can happen, but if it does
    // i don't want to deal with it at the moment
    if (cpu0.id != cpus.bsp_id) logger.panic("cpu 0 id != bootstrap id", .{});

    gdt.update(cpus.count) catch logger.panic("OOM while reinitializing GDT", .{});
    isr.newStacks(cpus.count) catch logger.panic("OOM while setting up ", .{});

    const wrap = struct {
        pub fn wrapped(cpu: *const limine.Cpu) callconv(.c) noreturn {
            gdt.load(cpu.extra);
            isr.storeStack();
            logger.debug("cpu {} online (acpi_id: {})", .{ getCpu(), info().acpi_id });
            entry();
        }
    };

    for (1..cpus.count) |i| {
        const cpu = cpus.cpus[i];
        cpu.extra = i;
        cpu.jump(wrap.wrapped);
    }

    cpu0.extra = 0;
    gdt.load(0);
    entry();
}

// CPU INFO

/// Use the GDT to identify the current CPU.
pub const getCpu = gdt.str;

pub inline fn info() *const limine.Cpu {
    return limine.cpus.response.cpus[getCpu()];
}

// THREAD-LOCAL STORAGE

const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn LocalStorage(comptime T: type) type {
    return struct {
        allocator: Allocator,
        objects: []T,

        const Self = @This();

        // INIT / DEINIT

        pub inline fn init(allocator: Allocator) !Self {
            const n = limine.cpus.response.count;
            return .{
                .allocator = allocator,
                .objects = try allocator.alloc(T, n),
            };
        }

        pub inline fn deinit(self: Self) void {
            self.allocator.free(self.objects);
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

        allocator: Allocator,
        objects: []Entry,

        const Entry = struct {
            lock: Lock = .{},
            value: T,
        };

        const Self = @This();

        // INIT / DEINIT

        pub inline fn init(allocator: Allocator) !Self {
            const n = limine.cpus.response.count;
            return .{
                .allocator = allocator,
                .objects = try allocator.alloc(Entry, n),
            };
        }

        pub inline fn deinit(self: Self) void {
            for (self.objects) |o| self.allocator.destroy(o.value);
            self.allocator.free(self.objects);
        }

        // LOCKING

        pub inline fn lockCpu(self: *Self, cpu: usize) *T {
            const object = &self.objects[cpu];
            object.lock.lock();
            return &object.value;
        }

        pub inline fn lock(self: *Self) *T {
            return self.lockCpu(getCpu());
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
