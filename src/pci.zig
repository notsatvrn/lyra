const std = @import("std");

const memory = @import("memory.zig");
const TreeMap = @import("utils").trees.Map;

const logger = @import("log.zig").Logger{ .name = "pci" };

// DEVICES

pub const Location = packed struct(u16) { func: u3, slot: u5, bus: u8 };
pub const Descriptor = packed struct(u32) { vendor: u16, device: u16 };
pub const Class = packed struct(u24) { interface: u8, subclass: u8, primary: u8 };
pub const Info = struct { desc: Descriptor, class: Class };

fn cmpLoc(a: Location, b: Location) std.math.Order {
    const bus_order = std.math.order(a.bus, b.bus);
    if (bus_order != .eq) return bus_order;
    const slot_order = std.math.order(a.slot, b.slot);
    if (slot_order != .eq) return slot_order;
    return std.math.order(a.func, b.func);
}

// use an AVL tree map to store devices, benefits from fast search and small size
pub const Devices = TreeMap(Location, Info, cmpLoc, .avl, true);
pub var devices = Devices.init(memory.allocator);

// CONFIGURATION SPACE (ACCESS MECHANISM #1)
// https://osdev.wiki/wiki/PCI#Configuration_Space_Access_Mechanism_#1

const io = @import("io.zig");
const rng = @import("rng.zig");

const CONFIG_ADDRESS = 0xCF8;
const CONFIG_DATA = 0xCFC;

inline fn configRead(comptime T: type, location: Location, offset: u8) T {
    const ConfigAddress = packed struct(u32) {
        offset: u8,
        location: Location,
        reserved: u7 = 0,
        enable: bool,
    };

    const addr = ConfigAddress{
        .offset = offset & 0xFC,
        .location = location,
        .enable = true,
    };

    io.out(u32, CONFIG_ADDRESS, @bitCast(addr));
    const tmp = io.in(u32, CONFIG_DATA);
    return switch (T) {
        u8 => @truncate(tmp >> @truncate(8 * (offset % 4))),
        u16 => @truncate(tmp >> @truncate(8 * (offset % 4))),
        u32 => tmp,
        else => @compileError("configRead type must be u8, u16, or u32"),
    };
}

pub fn init() void {
    logger.debug("devices:", .{});
    const num = detectBus(0) catch unreachable;
    logger.info("found {} devices", .{num});
}

fn detectBus(bus: u8) std.mem.Allocator.Error!usize {
    var num: usize = 0;
    slots: for (0..32) |slot| {
        for (0..8) |func| {
            defer rng.clockEntropy();

            const location = Location{
                .func = @truncate(func),
                .slot = @truncate(slot),
                .bus = bus,
            };

            const vendor = configRead(u16, location, 0);
            // no vendors are 0xFFFF, must be empty
            if (vendor == 0xFFFF) continue;

            const device = configRead(u16, location, 2);

            const class = Class{
                .primary = configRead(u8, location, 11),
                .subclass = configRead(u8, location, 10),
                .interface = configRead(u8, location, 9),
            };

            const params = .{ bus, slot, func, vendor, device, @as(u24, @bitCast(class)) };
            logger.debug("- {x:0>2}:{x:0>2}.{x} -> {x:0>4}:{x:0>4} (0x{x:0>6})", params);

            const desc = Descriptor{ .vendor = vendor, .device = device };
            try devices.put(location, .{ .desc = desc, .class = class });
            num += 1;

            const header_type = configRead(u8, location, 14);

            if (header_type & 0xF == 0x1) {
                // PCI-to-PCI bridge, let's read the next bus
                const next_bus = configRead(u8, location, 0x19);
                num += try detectBus(next_bus);
            }

            if (func == 0) {
                // if bit 7 is set, this is a multi-function device
                if (header_type >> 7 != 1) continue :slots;
            }
        }
    }
    return num;
}
