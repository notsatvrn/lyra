const std = @import("std");
const limine = @import("limine.zig");
const memory = @import("memory.zig");
const util = @import("util.zig");
const clock = @import("clock.zig");

const logger = @import("log.zig").Logger{ .name = "acpi" };

// uACPI IMPLEMENTATION

pub const c = @cImport({
    @cInclude("uacpi/uacpi.h");
    @cInclude("uacpi/acpi.h");
    @cInclude("uacpi/tables.h");
});

export fn uacpi_kernel_get_rsdp(rsdp: *c.uacpi_phys_addr) callconv(.c) c.uacpi_status {
    rsdp.* = @intFromPtr(limine.rsdp.response.ptr);
    return c.UACPI_STATUS_OK;
}

export fn uacpi_kernel_map(phys: c.uacpi_phys_addr, len: c.uacpi_size) callconv(.c) ?*anyopaque {
    return @ptrFromInt(memory.vmm.mapSimple(phys, len, .{ .writable = true }));
}
export fn uacpi_kernel_unmap(virt: ?*anyopaque, len: c.uacpi_size) callconv(.c) void {
    memory.vmm.unmapSimple(@intFromPtr(virt), len);
}

export fn uacpi_kernel_log(level: c.uacpi_log_level, str: [*c]const u8) callconv(.c) void {
    // trace = 5, debug = 4, we treat them the same way
    // otherwise it's the same as std.log.Level + 1
    const lvl = @min(level - 1, 3);
    const slice = std.mem.span(str);
    const msg = std.mem.trimEnd(u8, slice, " \n");
    logger.log(@enumFromInt(lvl), "{s}", .{msg});
}

export fn uacpi_kernel_io_map(base: c.uacpi_io_addr, _: c.uacpi_size, handle: *c.uacpi_handle) callconv(.c) c.uacpi_status {
    handle.* = @ptrFromInt(base);
    return c.UACPI_STATUS_OK;
}
export fn uacpi_kernel_io_unmap(_: c.uacpi_handle) void {}

export fn uacpi_kernel_io_read8(port: c.uacpi_handle, offset: c.uacpi_size, out: *u8) callconv(.c) c.uacpi_status {
    out.* = util.in(u8, @truncate(@intFromPtr(port) + offset));
    return c.UACPI_STATUS_OK;
}
export fn uacpi_kernel_io_read16(port: c.uacpi_handle, offset: c.uacpi_size, out: *u16) callconv(.c) c.uacpi_status {
    out.* = util.in(u16, @truncate(@intFromPtr(port) + offset));
    return c.UACPI_STATUS_OK;
}
export fn uacpi_kernel_io_read32(port: c.uacpi_handle, offset: c.uacpi_size, out: *u32) callconv(.c) c.uacpi_status {
    out.* = util.in(u32, @truncate(@intFromPtr(port) + offset));
    return c.UACPI_STATUS_OK;
}

export fn uacpi_kernel_io_write8(port: c.uacpi_handle, offset: c.uacpi_size, in: u8) callconv(.c) c.uacpi_status {
    util.out(u8, @truncate(@intFromPtr(port) + offset), in);
    return c.UACPI_STATUS_OK;
}
export fn uacpi_kernel_io_write16(port: c.uacpi_handle, offset: c.uacpi_size, in: u16) callconv(.c) c.uacpi_status {
    util.out(u16, @truncate(@intFromPtr(port) + offset), in);
    return c.UACPI_STATUS_OK;
}
export fn uacpi_kernel_io_write32(port: c.uacpi_handle, offset: c.uacpi_size, in: u32) callconv(.c) c.uacpi_status {
    util.out(u32, @truncate(@intFromPtr(port) + offset), in);
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

export fn uacpi_kernel_get_nanoseconds_since_boot() callconv(.c) u64 {
    return clock.nanoSinceBoot();
}
export fn uacpi_kernel_stall(usec: c.uacpi_u8) callconv(.c) void {
    clock.stall(@as(usize, usec) * std.time.ns_per_us);
}

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

pub const Address = packed struct {
    address_space: u8,
    bit_width: u8,
    bit_offset: u8,
    access_size: u8,
    address: u64,

    const AddressSpace = enum(u8) {
        memory,
        io,
        pci,
        ec,
        smbus,
        cmos,
        pci_bar_target,
        ipmi,
        gpio,
        serial,
        pcc,
        _,
    };

    pub inline fn addressSpace(self: Address) ?AddressSpace {
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

    reset_reg: Address,
    reset_value: u8,
    _reserved3: u24,

    firmware_ctrl: u64,
    dsdt: u64,

    pm1a_evt_blk: Address,
    pm1b_evt_blk: Address,
    pm1a_cnt_blk: Address,
    pm1b_cnt_blk: Address,
    pm2_cnt_blk: Address,
    pm_tmr_blk: Address,
    gpe0_blk: Address,
    gpe1_blk: Address,
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
    address: Address,
    hpet_number: u8,
    minimum_tick: u16,
    page_protection: u8,

    pub inline fn timers(self: *const Hpet) usize {
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
