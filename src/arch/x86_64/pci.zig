const std = @import("std");

const pci = @import("../../pci.zig");
const DeviceLocation = pci.DeviceLocation;
const Class = pci.Class;

const io = @import("io.zig");

// only for debugging purposes
const log = @import("../../log.zig");
const logger = log.Logger{ .name = "x86-64/pci" };

// CONFIGURATION SPACE (ACCESS MECHANISM #1)
// https://osdev.wiki/wiki/PCI#Configuration_Space_Access_Mechanism_#1

const CONFIG_ADDRESS = 0xCF8;
const CONFIG_DATA = 0xCFC;

pub inline fn configRead(comptime T: type, location: DeviceLocation, offset: u8) T {
    const ConfigAddress = packed struct(u32) {
        offset: u8,
        location: DeviceLocation,
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

pub inline fn detect() !void {
    try detectBus(0);
}

fn detectBus(bus: u8) !void {
    slots: for (0..32) |slot| {
        for (0..8) |func| {
            const location = DeviceLocation{
                .func = @truncate(func),
                .slot = @truncate(slot),
                .bus = bus,
            };

            const vendor = configRead(u16, location, 0);
            // no vendors are 0xFFFF, must be empty
            if (vendor == 0xFFFF) continue;

            const device = configRead(u16, location, 2);

            const primary = configRead(u8, location, 11);
            const subclass = configRead(u8, location, 10);
            const interface = configRead(u8, location, 9);
            const class = Class.parse(primary, subclass, interface) orelse {
                logger.debug(
                    "invalid hardware found {x} {x} {x}",
                    .{ primary, subclass, interface },
                );
                continue;
            };

            try pci.devices.put(location, .{ .vendor = vendor, .device = device, .class = class });

            const header_type = configRead(u8, location, 14);

            if (header_type & 0xF == 0x1) {
                // PCI-to-PCI bridge, let's read the next bus
                const next_bus = configRead(u8, location, 0x19);
                logger.debug("found a PCI-to-PCI bridge, reading bus {}", .{next_bus});
                try detectBus(next_bus);
            }

            if (func == 0) {
                // if bit 7 is set, this is a multi-function device
                if (header_type >> 7 != 1) continue :slots;
            }
        }
    }
}
