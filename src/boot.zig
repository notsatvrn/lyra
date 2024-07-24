const multiboot = @import("multiboot.zig");

pub const BootInfo = struct {
    mem_lower: ?*void,
    mem_upper: ?*void,
    //boot_device: ?BootDevice,
    cmdline: []const u8,
    //modules: ?[]Module,
    symbols: ?Symbols,
    mmap: ?[]MMapEntry,

    const Self = @This();

    pub fn fromMultiboot(info: *const multiboot.BootInfo) Self {
        return .{
            // should be zero if flags[0] is not set (making them null)
            .mem_lower = @ptrFromInt(info.mem_lower),
            .mem_upper = @ptrFromInt(info.mem_upper),
            .cmdline = if ((info.flags >> 2) & 1 == 0) "" else cmdline: {
                const addr: usize = @intCast(info.mmap_addr);
                const ptr: [*]u8 = @ptrFromInt(addr);
                // find null
                var end: usize = 0;
                while (ptr[end] != 0) end +%= 1;
                // now we have len
                break :cmdline ptr[0 .. end +% 1];
            },
            //.modules = if ((info.flags >> 3) & 1 == 0) null else mods: {},
            .symbols = if ((info.flags >> 4) & 1 == 0 and (info.flags >> 5) & 1 == 0) null else info.sym,
            .mmap = if ((info.flags >> 6) & 1 == 0) null else mmap: {
                const ptr: [*]RawEntry = @ptrFromInt(info.mmap_addr);
                break :mmap ptr[0..info.mmap_length];
            },
        };
    }
};

pub const MMapEntryType = enum {
    available,
    reserved,

    const Self = @This();

    pub inline fn fromMultiboot(typ: u32) Self {
        return switch (typ) {
            1 => .available,
            else => .reserved,
        };
    }
};

pub const MMapEntry = struct {
    area: []u8,
};
