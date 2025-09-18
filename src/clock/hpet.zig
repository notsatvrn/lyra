//! https://wiki.osdev.org/HPET

const acpi = @import("../acpi.zig");
const memory = @import("../memory.zig");
const io = @import("../io.zig");

const CAP_ID = 0x000;

const CapIdReg = packed struct(u64) {
    revision: u8,
    timer_cap: u5,
    long_mode: bool,
    _reserved: u1,
    legacy_replacement: bool,
    vendor: u16,
    period: u32,

    pub inline fn timers(self: CapIdReg) usize {
        return @as(usize, self.timer_cap) + 1;
    }
};

const CONFIG = 0x010;

const ConfigReg = packed struct(u64) {
    counter_enabled: bool,
    legacy_replacement: bool,
    _reserved: u62,
};

var mapped: usize = 0;

pub fn check() bool {
    var uacpi_table: acpi.UAcpiTable = undefined;
    const status = acpi.c.uacpi_table_find_by_signature(acpi.c.ACPI_HPET_SIGNATURE, @ptrCast(&uacpi_table));
    if (status != acpi.c.UACPI_STATUS_OK or uacpi_table.ptr == null) return false;

    const addr = @as(*const acpi.Hpet, @ptrCast(@alignCast(uacpi_table.ptr.?))).address.address;
    // the HPET address is expected to be 4KiB boundary aligned, and the region is 1KiB
    mapped = memory.vmm.kernel.mapSimple(addr, 1024, .{ .writable = true, .uncached = true });

    const basics = io.memIn(CapIdReg, mapped);
    return (basics.period > 0) and (basics.period <= 0x05F5E100) and basics.long_mode;
}

const COUNTER = 0x0F0;

pub inline fn counter() u64 {
    return io.memIn(u64, mapped + COUNTER);
}

pub fn counterSpeed() u64 {
    @as(*volatile ConfigReg, @ptrFromInt(mapped + CONFIG)).counter_enabled = true;
    const period = io.memIn(CapIdReg, mapped + CAP_ID).period;
    const fs_per_s: u64 = 1000 * 1000 * 1000 * 1000 * 1000;
    return fs_per_s / period;
}
