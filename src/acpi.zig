const std = @import("std");

// uACPI IMPLEMENTATION

const c = @cImport(@cInclude("uacpi/uacpi.h"));

const limine = @import("limine.zig");

export fn uacpi_kernel_get_rsdp(rsdp: *c.uacpi_phys_addr) callconv(.C) c.uacpi_status {
    rsdp.* = @intFromPtr(limine.rsdp.response.ptr);
    return c.UACPI_STATUS_OK;
}

const memory = @import("memory.zig");
const PageSize = memory.PageSize;
const Entry = memory.ManagedPageTable.Entry;

const map_options = Entry{ .writable = true };

export fn uacpi_kernel_map(phys: c.uacpi_phys_addr, len: c.uacpi_size) callconv(.C) ?*anyopaque {
    memory.page_table_lock.lock();
    defer memory.page_table_lock.unlock();
    const virt = memory.mmio_start;
    memory.mmio_start += (@as(usize, len) + PageSize.small.bytes()) & ~@as(usize, 0xFFF);
    memory.page_table.map(phys, virt, len, .small, map_options) catch
        log.panic(null, "uacpi_kernel_map failed", .{});
    memory.page_table.store();
    return @ptrFromInt(virt);
}
export fn uacpi_kernel_unmap(virt: ?*anyopaque, len: c.uacpi_size) callconv(.C) void {
    _ = virt;
    _ = len;
    // pretty sure we can just use limine's map for this (on base revision 2)
}

const log = @import("log.zig");
const logger = log.Logger{ .name = "uACPI" };

export fn uacpi_kernel_log(
    level: c.uacpi_log_level,
    str: [*c]const u8,
) callconv(.C) void {
    const slice = std.mem.span(str);
    // remove the new line at the end
    const msg = slice[0 .. slice.len - 1];
    switch (level) {
        c.UACPI_LOG_INFO => logger.info("{s}", .{msg}),
        c.UACPI_LOG_WARN => logger.warn("{s}", .{msg}),
        c.UACPI_LOG_ERROR => logger.err("{s}", .{msg}),
        c.UACPI_LOG_DEBUG | c.UACPI_LOG_TRACE => logger.debug("{s}", .{msg}),
        else => unreachable,
    }
}

// TODO: uacpi_kernel_pci_device_open
// TODO: uacpi_kernel_pci_device_close

// TODO: uacpi_kernel_pci_read8
// TODO: uacpi_kernel_pci_read16
// TODO: uacpi_kernel_pci_read32

// TODO: uacpi_kernel_pci_write8
// TODO: uacpi_kernel_pci_write16
// TODO: uacpi_kernel_pci_write32

// TODO: uacpi_kernel_io_map
// TODO: uacpi_kernel_io_unmap

// TODO: uacpi_kernel_io_read8
// TODO: uacpi_kernel_io_read16
// TODO: uacpi_kernel_io_read32

// TODO: uacpi_kernel_io_write8
// TODO: uacpi_kernel_io_write16
// TODO: uacpi_kernel_io_write32

export fn uacpi_kernel_alloc(size: c.uacpi_size) callconv(.C) ?*anyopaque {
    const mem = memory.allocator.alloc(u8, @as(usize, size)) catch
        log.panic(null, "uacpi_kernel_alloc failed", .{});
    return @ptrCast(mem);
}
export fn uacpi_kernel_free(mem: ?*anyopaque, size: c.uacpi_size) callconv(.C) void {
    const bytes: [*]u8 = @ptrCast(mem);
    memory.allocator.free(bytes[0..size]);
}

const clock = @import("clock.zig");

export fn uacpi_kernel_get_nanoseconds_since_boot() callconv(.C) u64 {
    return clock.nanoSinceBoot();
}
export fn uacpi_kernel_stall(usec: c.uacpi_u8) callconv(.C) void {
    clock.stall(@as(usize, usec) * std.time.ns_per_us);
}

// TODO: a lot more i'm too lazy to write

// TODO: we need a spin lock that also disables interrupts
const SpinLock = @import("utils").lock.SpinLock;
var lock_pool = std.heap.MemoryPool(SpinLock).init(memory.allocator);

export fn uacpi_kernel_create_spinlock() callconv(.C) c.uacpi_handle {
    const lock = lock_pool.create() catch
        log.panic(null, "uacpi_kernel_create_spinlock failed", .{});
    return @ptrCast(lock);
}
export fn uacpi_kernel_free_spinlock(lock: c.uacpi_handle) callconv(.C) void {
    lock_pool.destroy(@ptrCast(@alignCast(lock)));
}
// TODO: uacpi_kernel_lock_spinlock
// TODO: uacpi_kernel_unlock_spinlock

// ACPI STRUCTURES

pub const Rsdp = extern struct {
    signature: [8]u8,
    checksum: u8,
    oem_id: [6]u8,
    revision: u8,
    rsdt_addr: u32,

    pub inline fn extended(self: *const Rsdp) ?*const Xsdp {
        if (self.revision != 2) return null;
        return @ptrCast(@alignCast(self));
    }

    pub inline fn sdt(self: *const Rsdp) *const SdtHeader {
        if (self.extended()) |x|
            return @ptrFromInt(x.xsdt_addr);
        return @ptrFromInt(self.rsdt_addr);
    }
};

pub const Xsdp = extern struct {
    signature: [8]u8,
    checksum: u8,
    oem_id: [6]u8,
    _revision: u8, // 2.0 is assumed
    _rsdt_addr: u32, // deprecated in 2.0

    length: u32,
    xsdt_addr: u64,
    ext_checksum: u8,
    _reserved: [3]u8,
};

// https://wiki.osdev.org/RSDT & https://wiki.osdev.org/XSDT

pub const SdtHeader = extern struct {
    signature: [4]u8,
    length: u32,
    revision: u8,
    checksum: u8,
    oem_id: [6]u8,
    oem_table_id: [8]u8,
    oem_revision: u32,
    creator_id: u32,
    creator_revision: u32,

    pub fn doChecksum(self: *const SdtHeader) bool {
        const ptr: [*]const SdtHeader = @ptrCast(self);
        var sum: u8 = 0;

        for (0..self.length) |i|
            sum +%= ptr[i];

        return sum == 0;
    }
};

// uACPI WRAPPERS

pub fn init() void {
    const buffer = memory.map(.small, 1) orelse {
        log.panic(null, "failed to initialize uACPI: buffer creation failed", .{});
    };

    const status = c.uacpi_setup_early_table_access(@ptrCast(buffer), 4096);
    if (status != c.UACPI_STATUS_OK) {
        log.panic(null, "failed to initialize uACPI: {}", .{status});
        return;
    }
}
