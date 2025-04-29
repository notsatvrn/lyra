//! A simple interface to read and manipulate page tables on x86-64.

const std = @import("std");

const util = @import("util.zig");
const limine = @import("../../limine.zig");
const memory = @import("../../memory.zig");

// STRUCTURES

pub const PageTable = [512]Entry;

pub const Entry = packed struct(u64) {
    // zig fmt: off
    present:    bool = false,
    writable:   bool = false, // A page is only read-write if *both* the directory and entry are.
    user:       bool = false,
    write_thru: bool = false,
    uncached:   bool = false,
    accessed:   bool = false,
    level:      Level = .{ .directory = .{} },
    no_exec:    bool = false,

    pub const Level = packed union {
        directory: packed struct(u57) {
            _reserved0: u1 = 0,
            huge: bool = false,
            _reserved1: u4 = 0,

            address: u40 = 0,
            
            _reserved2: u7 = 0,
            _reserved3: u4 = 0, // PK in entry
        },
        entry: packed struct(u57) {
            dirty:  bool = false,
            pat:    bool = false,
            global: bool = false,
            _reserved0: u3 = 0,

            address: u40 = 0,
            
            _reserved1: u7 = 0,
            protection_key: u4 = 0,
        },
    };
    // zig fmt: on

    pub inline fn addr(self: Entry) usize {
        const mask = ((@as(u64, 1) << 40) - 1) << 12;
        const int: u64 = @bitCast(self);
        return int & mask;
    }
};

// LOAD/STORE PAGE TABLE POINTER

pub inline fn load() *PageTable {
    var addr = util.getRegister(u64, "cr3");
    addr |= limine.hhdm.response.offset;
    return @ptrFromInt(addr);
}

pub inline fn store(table: *const PageTable) void {
    var addr = @as(u64, @intFromPtr(table));
    addr &= ~limine.hhdm.response.offset;
    util.setRegister(u64, "cr3", addr);
}

// READ PAGE TABLE

inline fn index(level: usize, addr: usize) usize {
    const shift = 12 + ((level - 1) * 9);
    return (addr >> shift) & 0x1FF;
}

inline fn read(table: *const PageTable, level: usize, addr: usize) ?*const PageTable {
    const entry = table[index(level, addr)];
    if (!entry.present) return null;
    return @ptrFromInt(entry.addr());
}

pub fn physFromVirt(top: *const PageTable, addr: usize) ?usize {
    var table = top;

    if (limine.paging_mode.response.mode == 1) // 5-level paging is enabled
        table = limine.convertPointer(read(table, 5, addr) orelse return null);
    table = limine.convertPointer(read(table, 4, addr) orelse return null);

    // handle possible huge pages
    inline for (0..2) |i| {
        const entry = table[index(3 - i, addr)];
        if (!entry.present) return null;
        if (entry.level.directory.huge) return entry.addr();
        table = limine.convertPointer(@ptrFromInt(entry.addr()));
    }

    return @intFromPtr(read(table, 1, addr) orelse return null);
}
