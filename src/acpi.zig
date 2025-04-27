const std = @import("std");

pub const RSDP = extern struct {
    signature: [8]u8,
    checksum: u8,
    oem_id: [6]u8,
    revision: u8,
    rsdt_addr: u32,

    pub inline fn extended(self: *const RSDP) ?*const XSDP {
        if (self.revision != 2) return null;
        return @ptrCast(@alignCast(self));
    }

    pub inline fn sdt(self: *const RSDP) *const SDTHeader {
        if (self.extended()) |x|
            return @ptrFromInt(x.xsdt_addr);
        return @ptrFromInt(self.rsdt_addr);
    }
};

pub const XSDP = extern struct {
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

pub var sdt_start: *const SDTHeader = undefined;

pub const SDTHeader = extern struct {
    signature: [4]u8,
    length: u32,
    revision: u8,
    checksum: u8,
    oem_id: [6]u8,
    oem_table_id: [8]u8,
    oem_revision: u32,
    creator_id: u32,
    creator_revision: u32,

    pub fn doChecksum(self: *const SDTHeader) bool {
        const ptr: [*]const SDTHeader = @ptrCast(self);
        var sum: u8 = 0;

        for (0..self.length) |i|
            sum +%= ptr[i];

        return sum == 0;
    }
};
