const std = @import("std");

const util = @import("../util.zig");
const cpuid = @import("../cpuid.zig");
const limine = @import("../limine.zig");
const memory = @import("../memory.zig");
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

    pub inline fn setAddr(self: *Entry, addr: usize) void {
        self.address = @truncate(addr >> 12);
    }

    pub inline fn getAddr(self: Entry) usize {
        const mask = ((@as(u64, 1) << 35) - 1) << 12;
        return @as(u64, @bitCast(self)) & mask;
    }

    /// Set an entry's flags to the flags from another entry.
    pub inline fn setFlags(self: *Entry, flags: Entry) void {
        // zig fmt: off
        self.writable   = flags.writable;
        self.user       = flags.user;
        self.write_thru = flags.write_thru;
        self.uncached   = flags.uncached;
        self.prot_key   = flags.prot_key;
        self.no_exec    = flags.no_exec;
        // zig fmt: on
    }

    /// Returns a blank entry with the original entry's flags.
    pub inline fn getFlags(self: Entry, present: bool) Entry {
        var flags = Entry{ .present = present };
        flags.setFlags(self);
        return flags;
    }
};

pub const Pool = @import("object_pool.zig").ObjectPool(PageTable, .{});

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

pub fn mapRecursive(table: *PageTable, pool: *Pool, level: u3, s: usize, e: usize, p: ?usize, size: Size, flags: Entry) !void {
    const start_idx = index(level, s);
    const end_idx = index(level, e);
    const unmap = p == null;

    const entry_bytes = @as(usize, 1) << shift(level);
    var phys = p;
    var start = s;
    // round start up to nearest entry_bytes for end
    var end = (s + entry_bytes - 1) & ~(entry_bytes - 1);
    // don't go past e
    end = @min(e, end);

    for (start_idx..end_idx + 1) |i| {
        const entry = &table[i];
        if (level == @intFromEnum(size)) {
            if (entry.present)
                cleanEntry(entry, pool, size);
            if (!unmap) {
                entry.present = true;
                entry.setFlags(flags);
                entry.level.directory.huge = size != .small;
                entry.setAddr(phys.?);
            } else {
                entry.* = .{};
                continue;
            }
        } else {
            if (!entry.present) {
                if (unmap) continue;
                entry.* = flags; // start a new entry
                entry.setAddr(@intFromPtr(try pool.create()) - limine.hhdm.response.offset);
            } else prepare: {
                if (!unmap) entry.setFlags(flags);
                // convert hugepage to smaller pages we can map in
                if (!entry.level.directory.huge) break :prepare;
                entry.level.directory.huge = false;
                const old_size: Size = @enumFromInt(@as(u2, @truncate(level)));
                try downmapEntry(entry, pool, flags, old_size, size);
            }
            // now we have a directory, and we can start mapping in it
            const next_table: *PageTable = @ptrFromInt(entry.getAddr() + limine.hhdm.response.offset);
            try mapRecursive(next_table, pool, level - 1, start, end, phys, size, flags);
            start += entry_bytes;
            end = @min(e, end + entry_bytes);
            if (unmap) continue;
        }
        // phys can't be null
        phys.? += entry_bytes;
    }
}

/// Deallocate a present entry's child tables.
fn cleanEntry(entry: *Entry, pool: *Pool, size: Size) void {
    if (size == .small or entry.level.directory.huge) return;
    // we're changing this to a hugepage but it used to be a table
    const table: *PageTable = @ptrFromInt(entry.getAddr() + limine.hhdm.response.offset);
    defer pool.destroy(table);
    // large page level may have tables below it (4KiB -> 1GiB)
    if (size == .large) for (0..512) |i| {
        const e = &table[i];
        if (!e.present or e.level.directory.huge) continue;
        const t: *PageTable = @ptrFromInt(e.getAddr() + limine.hhdm.response.offset);
        pool.destroy(t);
    };
}

/// Convert a present hugepage entry to a smaller page size.
/// Useful when trying to map or unmap inside a hugepage.
fn downmapEntry(entry: *Entry, pool: *Pool, flags: Entry, from: Size, to: Size) !void {
    // if the original size is smaller or equal, we can't downmap
    std.debug.assert(@intFromEnum(from) > @intFromEnum(to));
    // copy the page entry (with address) for lower entries
    var bottom = entry.*;
    // make the new page table
    const table = try pool.create();
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
            const tables = try pool.createBin();
            for (0..512) |i| {
                table[i] = flags;
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
