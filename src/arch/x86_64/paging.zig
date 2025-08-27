//! Paging helpers implementation for x86-64.

const std = @import("std");

const util = @import("util.zig");
const cpuid = @import("cpuid.zig");
const limine = @import("../../limine.zig");
const memory = @import("../../memory.zig");
const allocator = memory.page_allocator;
const Size = memory.PageSize;

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
    _reserved0: u3  = 0,
    address:    u35 = 0,
    _reserved1: u12 = 0,
    prot_key:   u4  = 0,
    no_exec:    bool = false,

    pub const Level = packed union {
        directory: packed struct(u3) {
            _reserved0: u1 = 0,
            huge: bool = false,
            _reserved1: u1 = 0,
        },
        entry: packed struct(u3) {
            dirty:  bool = false,
            pat:    bool = false,
            global: bool = false,
        },
    };
    // zig fmt: on

    pub inline fn getAddr(self: Entry) usize {
        const mask = ((@as(u64, 1) << 35) - 1) << 12;
        return @as(u64, @bitCast(self)) & mask;
    }

    pub inline fn setAddr(self: *Entry, addr: usize) void {
        self.address = @truncate(addr >> 12);
    }

    /// Wipes an entry to keep just the basic flags for writing new entries.
    pub inline fn makeBase(self: Entry) Entry {
        var base = self;
        base.present = true;
        base.level = .{ .entry = .{} };
        base.accessed = false;
        return base;
    }
};

// LOAD/STORE PAGE TABLE POINTER

pub inline fn load() *PageTable {
    var addr = util.getRegister(u64, "cr3");
    addr += limine.hhdm.response.offset;
    return @ptrFromInt(addr);
}

pub inline fn store(table: *const PageTable) void {
    var addr: u64 = @intFromPtr(table);
    addr -= limine.hhdm.response.offset;
    util.setRegister(u64, "cr3", addr);
}

// READ PAGE TABLE

inline fn shift(level: u3) u6 {
    return 3 + (@as(u6, level) * 9);
}

inline fn index(level: u3, addr: usize) usize {
    return (addr >> shift(level)) & 0x1FF;
}

inline fn read(table: *const PageTable, level: u3, addr: usize) ?*const PageTable {
    const entry = table[index(level, addr)];
    if (!entry.present) return null;
    return @ptrFromInt(entry.getAddr() + limine.hhdm.response.offset);
}

pub fn physFromVirt(top: *const PageTable, addr: usize) ?usize {
    var table = top;

    if (cpuid.features.pml5) // 5-level paging is enabled
        table = read(table, 5, addr) orelse return null;
    table = read(table, 4, addr) orelse return null;

    // handle possible huge pages
    inline for (0..2) |i| {
        const entry = table[index(3 - i, addr)];
        const bits = 12 + ((2 - i) * 9);
        const mask = (@as(usize, 1) << bits) - 1;
        if (!entry.present) return null;
        if (entry.level.directory.huge) return entry.getAddr() + (addr & mask);
        table = @ptrFromInt(entry.getAddr() + limine.hhdm.response.offset);
    }

    const entry = table[index(1, addr)];
    if (!entry.present) return null;
    return entry.getAddr() + (addr & 0xFFF);
}

// WRITE PAGE TABLE

pub fn mapRecursive(table: *PageTable, level: u3, s: usize, e: usize, p: usize, size: Size, base: Entry) !void {
    const start_idx = index(level, s);
    const end_idx = index(level, e);

    const entry_bytes = @as(usize, 1) << shift(level);
    var phys = p;
    var start = s;
    // round start up to nearest entry_bytes for end
    var end = (s + entry_bytes) & ~(entry_bytes - 1);
    // don't go past e
    end = @min(e, end);

    for (start_idx..end_idx + 1) |i| {
        const entry = &table[i];

        if (entry.present) {
            // write the entry attributes
            entry.writable = base.writable;
            entry.user = base.user;
            entry.write_thru = base.write_thru;
            entry.uncached = base.uncached;
            entry.no_exec = base.no_exec;
        }

        if (level == @intFromEnum(size)) {
            // we've reached the page level
            mapEnd(entry, size, base, phys);
        } else {
            if (!entry.present) {
                // entry not present, make a new one
                entry.* = base; // start with the base
                const new_table = try allocator.create(PageTable);
                entry.setAddr(@intFromPtr(new_table) - limine.hhdm.response.offset);
            } else if (entry.level.directory.huge) {
                // convert hugepage to smaller pages we can map in
                const old_size: Size = @enumFromInt(@as(u2, @truncate(level)));
                try downmapEntry(entry, base, old_size, size);
            }
            // now we have a directory, and we can start mapping in it
            const next_table: *PageTable = @ptrFromInt(entry.getAddr() + limine.hhdm.response.offset);
            try mapRecursive(next_table, level - 1, start, end, phys, size, base);
            start += entry_bytes;
            end = @min(e, end + entry_bytes);
        }
        phys += entry_bytes;
    }
}

/// Handle mapping at the page level, where we set the physical address.
fn mapEnd(entry: *Entry, size: Size, base: Entry, addr: usize) void {
    const level = @intFromEnum(size);

    if (!entry.present) {
        entry.* = base;
    } else if (level > 1 and !entry.level.directory.huge) huge: {
        // we're changing this to a hugepage but it used to be a table
        const table: *PageTable = @ptrFromInt(entry.getAddr() + limine.hhdm.response.offset);
        defer allocator.destroy(table);
        // level 3 has tables below it (4KiB -> 1GiB)
        if (level != 3) break :huge;
        for (0..512) |i| {
            const e = &table[i];
            if (!e.present) continue;
            const t: *PageTable = @ptrFromInt(e.getAddr() + limine.hhdm.response.offset);
            allocator.destroy(t);
        }
    }

    // level 2 is 2MB hugepage, level 3 is 1GB hugepage
    if (level > 1) entry.level.directory.huge = true;
    entry.setAddr(addr);
}

/// Convert a hugepage entry to a smaller page size.
/// Useful when trying to map or unmap inside a hugepage.
fn downmapEntry(entry: *Entry, base: Entry, from: Size, to: Size) !void {
    // if the original size is smaller or equal, we can't downmap
    std.debug.assert(@intFromEnum(from) > @intFromEnum(to));
    // copy the page entry (with address) for lower entries
    var bottom = entry.*;
    // make the new page table
    entry.* = base; // reset entry to directory
    const table = try allocator.create(PageTable);
    entry.setAddr(@intFromPtr(table) - limine.hhdm.response.offset);
    // fill the new page table
    switch (@intFromEnum(from) - @intFromEnum(to)) {
        // 1GiB -> 2MiB or 2MiB -> 4KiB
        1 => {
            const offset = @as(u35, 1) << (to.shift() - 12);
            // still a hugepage if we're doing 1GiB -> 2MiB
            bottom.level.directory.huge = to == .medium;
            for (0..512) |i| {
                table[i] = bottom;
                bottom.address += offset;
            }
        },
        // 1GiB -> 4KiB
        2 => {
            const tables = try allocator.alloc(PageTable, 512);
            // 4KiB is the only possible page size here
            bottom.level.directory.huge = false;
            for (0..512) |i| {
                table[i] = base;
                table[i].setAddr(@intFromPtr(&tables[i]));
                for (0..512) |j| {
                    tables[i][j] = bottom;
                    bottom.address += 1;
                }
            }
        },
        else => unreachable,
    }
}

pub inline fn unmap(top: *PageTable, virt: usize, pages: usize, size: Size) void {
    const page_bytes = size.bytes();

    _ = top;
    _ = virt;
    _ = pages;
    _ = page_bytes;
}
