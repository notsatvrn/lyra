//! https://wiki.osdev.org/ACPI_Timer

const acpi = @import("../acpi.zig");

var fadt: *acpi.Fadt = undefined;

pub inline fn check() bool {
    var ptr: ?*acpi.c.struct_acpi_fadt = null;
    const status = acpi.c.uacpi_table_fadt(@ptrCast(&ptr));
    if (status != acpi.c.UACPI_STATUS_OK or ptr == null) return false;

    fadt = @ptrCast(@alignCast(ptr.?));
    return fadt.pm_tmr_len == 4;
}
