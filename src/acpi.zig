const std = @import("std");

const logger = @import("log.zig").Logger{ .name = "acpi" };

// uACPI IMPLEMENTATION

pub const c = @cImport({
    @cInclude("uacpi/uacpi.h");
    @cInclude("uacpi/acpi.h");
    @cInclude("uacpi/tables.h");
});

const limine = @import("limine.zig");

export fn uacpi_kernel_get_rsdp(rsdp: *c.uacpi_phys_addr) callconv(.c) c.uacpi_status {
    rsdp.* = @intFromPtr(limine.rsdp.response.ptr);
    return c.UACPI_STATUS_OK;
}

const memory = @import("memory.zig");
const PageSize = memory.PageSize;
const vmm = memory.vmm;
const Entry = vmm.ManagedPageTable.Entry;

const map_flags = Entry{ .writable = true };

export fn uacpi_kernel_map(phys: c.uacpi_phys_addr, len: c.uacpi_size) callconv(.c) ?*anyopaque {
    return @ptrFromInt(vmm.kernel.mapIo(phys, len, map_flags));
}
export fn uacpi_kernel_unmap(virt: ?*anyopaque, len: c.uacpi_size) callconv(.c) void {
    vmm.kernel.unmap(@intFromPtr(virt), len, .small);
}

export fn uacpi_kernel_log(
    level: c.uacpi_log_level,
    str: [*c]const u8,
) callconv(.c) void {
    const slice = std.mem.span(str);
    const msg = std.mem.trimEnd(u8, slice, " \n");
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

const io = @import("io.zig");

export fn uacpi_kernel_io_map(base: c.uacpi_io_addr, _: c.uacpi_size, handle: *c.uacpi_handle) callconv(.c) c.uacpi_status {
    handle.* = @ptrFromInt(base);
    return c.UACPI_STATUS_OK;
}
export fn uacpi_kernel_io_unmap(_: c.uacpi_handle) void {}

export fn uacpi_kernel_io_read8(port: c.uacpi_handle, offset: c.uacpi_size, out: *u8) callconv(.c) c.uacpi_status {
    out.* = io.in(u8, @truncate(@intFromPtr(port) + offset));
    return c.UACPI_STATUS_OK;
}
export fn uacpi_kernel_io_read16(port: c.uacpi_handle, offset: c.uacpi_size, out: *u16) callconv(.c) c.uacpi_status {
    out.* = io.in(u16, @truncate(@intFromPtr(port) + offset));
    return c.UACPI_STATUS_OK;
}
export fn uacpi_kernel_io_read32(port: c.uacpi_handle, offset: c.uacpi_size, out: *u32) callconv(.c) c.uacpi_status {
    out.* = io.in(u32, @truncate(@intFromPtr(port) + offset));
    return c.UACPI_STATUS_OK;
}

export fn uacpi_kernel_io_write8(port: c.uacpi_handle, offset: c.uacpi_size, in: u8) callconv(.c) c.uacpi_status {
    io.out(u8, @truncate(@intFromPtr(port) + offset), in);
    return c.UACPI_STATUS_OK;
}
export fn uacpi_kernel_io_write16(port: c.uacpi_handle, offset: c.uacpi_size, in: u16) callconv(.c) c.uacpi_status {
    io.out(u16, @truncate(@intFromPtr(port) + offset), in);
    return c.UACPI_STATUS_OK;
}
export fn uacpi_kernel_io_write32(port: c.uacpi_handle, offset: c.uacpi_size, in: u32) callconv(.c) c.uacpi_status {
    io.out(u32, @truncate(@intFromPtr(port) + offset), in);
    return c.UACPI_STATUS_OK;
}

export fn uacpi_kernel_alloc(size: c.uacpi_size) callconv(.c) ?*anyopaque {
    const mem = memory.allocator.alloc(u8, @as(usize, size)) catch
        logger.panic("uacpi_kernel_alloc failed", .{});
    return @ptrCast(mem);
}
export fn uacpi_kernel_free(mem: ?*anyopaque, size: c.uacpi_size) callconv(.c) void {
    const bytes: [*]u8 = @ptrCast(mem);
    memory.allocator.free(bytes[0..size]);
}

const clock = @import("clock.zig");

export fn uacpi_kernel_get_nanoseconds_since_boot() callconv(.c) u64 {
    return clock.nanoSinceBoot();
}
export fn uacpi_kernel_stall(usec: c.uacpi_u8) callconv(.c) void {
    clock.stall(@as(usize, usec) * std.time.ns_per_us);
}

// TODO: a lot more i'm too lazy to write

// TODO: we need a spin lock that also disables interrupts
const SpinLock = @import("utils").lock.SpinLock;
var lock_pool = std.heap.MemoryPool(SpinLock).init(memory.allocator);

export fn uacpi_kernel_create_spinlock() callconv(.c) c.uacpi_handle {
    const lock = lock_pool.create() catch
        logger.panic("uacpi_kernel_create_spinlock failed", .{});
    return @ptrCast(lock);
}
export fn uacpi_kernel_free_spinlock(lock: c.uacpi_handle) callconv(.c) void {
    lock_pool.destroy(@ptrCast(@alignCast(lock)));
}
// TODO: uacpi_kernel_lock_spinlock
// TODO: uacpi_kernel_unlock_spinlock

// ACPI STRUCTURES

pub const Rsdp = packed struct {
    signature: u64,
    checksum: u8,
    oem_id: u48,
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

pub const Xsdp = packed struct {
    signature: u64,
    checksum: u8,
    oem_id: u48,
    _revision: u8, // 2.0 is assumed
    _rsdt_addr: u32, // deprecated in 2.0

    length: u32,
    xsdt_addr: u64,
    ext_checksum: u8,
    _reserved: u24,
};

/// https://wiki.osdev.org/RSDT & https://wiki.osdev.org/XSDT
pub const SdtHeader = packed struct {
    signature: u32,
    length: u32,
    revision: u8,
    checksum: u8,
    oem_id: u48,
    oem_table_id: u64,
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

pub const Gas = packed struct {
    address_space: u8,
    bit_width: u8,
    bit_offset: u8,
    access_size: u8,
    address: u64,

    const AddressSpace = enum(u8) {
        memory = 0x0,
        io = 0x0,
        pci = 0x2,
        ec = 0x3,
        smbus = 0x4,
        cmos = 0x5,
        pci_bar_target = 0x6,
        ipmi = 0x7,
        gpio = 0x8,
        serial = 0x9,
        pcc = 0xA,
    };

    pub inline fn addressSpace(self: Gas) ?AddressSpace {
        if (self.address_space > 0xA) return null;
        return @enumFromInt(self.address_space);
    }
};

/// https://wiki.osdev.org/FADT
pub const Fadt = packed struct {
    header: SdtHeader,
    // 32-bit legacy addresses
    _firmware_ctrl: u32,
    _dsdt: u32,

    _reserved: u8, // deprecated in 2.0

    preferred_pm_profile: u8,
    sci_int: u16,
    smi_cmd: u16,
    acpi_enable: u8,
    acpi_disable: u8,
    s4bios_req: u8,
    pstate_cnt: u8,
    // start 32-bit legacy addresses
    _pm1a_evt_blk: u32,
    _pm1b_evt_blk: u32,
    _pm1a_cnt_blk: u32,
    _pm1b_cnt_blk: u32,
    _pm2_cnt_blk: u32,
    _pm_tmr_blk: u32,
    _gpe0_blk: u32,
    _gpe1_blk: u32,
    // end 32-bit legacy addresses
    pm1_evt_len: u8,
    pm1_cnt_len: u8,
    pm2_cnt_len: u8,
    pm_tmr_len: u8,
    gpe0_blk_len: u8,
    gpe1_blk_len: u8,
    gpe1_base: u8,
    cst_cnt: u8,
    p_lvl2_lat: u16,
    p_lvl3_lat: u16,
    flush_size: u16,
    flush_stride: u16,
    duty_offset: u8,
    duty_width: u8,
    day_alarm: u8,
    mon_alarm: u8,
    century: u8,

    boot_arch_flags: u16,

    _reserved2: u8,
    flags: u32,

    reset_reg: Gas,
    reset_value: u8,
    _reserved3: u24,

    firmware_ctrl: u64,
    dsdt: u64,

    pm1a_evt_blk: Gas,
    pm1b_evt_blk: Gas,
    pm1a_cnt_blk: Gas,
    pm1b_cnt_blk: Gas,
    pm2_cnt_blk: Gas,
    pm_tmr_blk: Gas,
    gpe0_blk: Gas,
    gpe1_blk: Gas,
};

/// https://wiki.osdev.org/HPET
pub const Hpet = packed struct {
    header: SdtHeader,
    hardware_rev_id: u8,
    comparator_count: u5,
    counter_size: u1,
    reserved: u1,
    legacy_replacement: u1,
    pci_vendor_id: u16,
    address: Gas,
    hpet_number: u8,
    minimum_tick: u16,
    page_protection: u8,

    pub inline fn timers(self: Hpet) usize {
        return @as(usize, self.comparator_count) + 1;
    }
};

// uACPI WRAPPERS

pub fn init() void {
    const buffer = memory.page_allocator.alloc(u8, 4096) catch
        logger.panic("failed to initialize uACPI: buffer creation failed", .{});

    const status = c.uacpi_setup_early_table_access(@ptrCast(buffer), 4096);
    if (status != c.UACPI_STATUS_OK)
        logger.panic("failed to initialize uACPI: {}", .{status});
}

pub const deinit = c.uacpi_state_reset;

pub const UAcpiTable = extern struct {
    ptr: ?*SdtHeader,
    index: c.uacpi_size,
};
