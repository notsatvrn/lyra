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

    try arch.prepCpus(cpus.count);
    arch.setCpu(0);

    for (0..cpus.count) |i| {
        const cpu = cpus.cpus[i];
        cpu.extra = i;
        if (cpu.id != cpus.bsp_id)
            limine.jumpCpu(cpu, cpuEntry);
    }

    logger.debug("boot cpu was {} (acpi_id: {})", .{ arch.getCpu(), info().acpi_id });
}

// ENTRYPOINT

pub fn cpuEntry(cpu: *const limine.Cpu) callconv(.c) noreturn {
    arch.setCpu(cpu.extra);
    logger.debug("cpu {} online (acpi_id: {})", .{ arch.getCpu(), info().acpi_id });

    while (true) arch.util.wfi();
}

// CPU INFO

pub inline fn info() *const limine.Cpu {
    return limine.cpus.response.cpus[arch.getCpu()];
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
            return &self.objects[arch.getCpu()];
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
            return self.lockCpu(arch.getCpu());
        }

        // UNLOCKING

        pub inline fn unlockCpu(self: *Self, cpu: usize) void {
            self.objects[cpu].lock.unlock();
        }

        pub inline fn unlock(self: *Self) void {
            self.unlockCpu(arch.getCpu());
        }
    };
}
