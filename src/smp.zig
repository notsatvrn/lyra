const arch = @import("arch.zig");
const limine = @import("limine.zig");
const memory = @import("memory.zig");

const log = @import("log.zig");
const logger = log.Logger{ .name = "smp" };

// INITIALIZATION

pub fn init() !void {
    const cpus = limine.cpus.response;

    // not sure if this can happen, but if it does
    // i don't want to deal with it at the moment
    if (cpus.cpus[0].id != cpus.bsp_id)
        @panic("cpu 0 id != bootstrap id");

    try arch.prepCPUs(cpus.count);
    arch.setCPU(0);

    for (0..cpus.count) |i| {
        const cpu = cpus.cpus[i];
        cpu.extra = i;
        if (cpu.id != cpus.bsp_id)
            limine.jumpCPU(cpu, cpuEntry);
    }

    logger.debug("boot cpu was {} (acpi_id: {})", .{ arch.getCPU(), info().acpi_id });
}

// ENTRYPOINT

pub fn cpuEntry(cpu: *const limine.CPU) callconv(.c) noreturn {
    arch.setCPU(cpu.extra);
    logger.debug("cpu {} online (acpi_id: {})", .{ arch.getCPU(), info().acpi_id });

    arch.halt();
}

// CPU INFO

pub inline fn info() *const limine.CPU {
    return limine.cpus.response.cpus[arch.getCPU()];
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
            return &self.objects[arch.getCPU()];
        }
    };
}

pub fn LockingStorage(comptime T: type) type {
    return struct {
        const Lock = @import("util/lock.zig").SpinLock;

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

        pub inline fn lockCPU(self: *Self, cpu: usize) *T {
            const object = &self.objects[cpu];
            object.lock.lock();
            return &object.value;
        }

        pub inline fn lock(self: *Self) *T {
            return self.lockCPU(arch.getCPU());
        }

        // UNLOCKING

        pub inline fn unlockCPU(self: *Self, cpu: usize) void {
            self.objects[cpu].lock.unlock();
        }

        pub inline fn unlock(self: *Self) void {
            self.unlockCPU(arch.getCPU());
        }
    };
}
