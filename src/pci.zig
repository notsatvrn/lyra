const std = @import("std");

const memory = @import("memory.zig");
const TreeMap = @import("utils").trees.Map;

const logger = @import("log.zig").Logger{ .name = "pci" };

// DEVICES

pub const DeviceLocation = packed struct(u16) { func: u3, slot: u5, bus: u8 };
pub const DeviceDescriptor = packed struct(u32) { vendor: u16, device: u16 };
pub const DeviceInfo = struct { desc: DeviceDescriptor, class: Class };

fn cmpLoc(a: DeviceLocation, b: DeviceLocation) std.math.Order {
    return std.math.order(@as(u16, @bitCast(a)), @as(u16, @bitCast(b)));
}

// use an AVL tree map to store devices, benefits from fast search and small size
pub const Devices = TreeMap(DeviceLocation, DeviceInfo, cmpLoc, .avl, true);
pub var devices = Devices.init(memory.allocator);

pub inline fn print() void {
    var iterator = devices.iterator(memory.allocator);
    logger.debug("devices:", .{});

    while (iterator.next() catch
        logger.panic("device printing failed (OOM)", .{})) |device|
    {
        logger.debug("- {x:0>2}:{x:0>2}.{x} ({x:0>4}:{x:0>4}) : {f}", .{
            device.key.bus,
            device.key.slot,
            device.key.func,
            device.value.desc.vendor,
            device.value.desc.device,
            device.value.class,
        });
    }

    iterator.deinit();
}

// CONFIGURATION SPACE (ACCESS MECHANISM #1)
// https://osdev.wiki/wiki/PCI#Configuration_Space_Access_Mechanism_#1

const io = @import("io.zig");

const CONFIG_ADDRESS = 0xCF8;
const CONFIG_DATA = 0xCFC;

fn configRead(comptime T: type, location: DeviceLocation, offset: u8) T {
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

pub inline fn detect() void {
    detectBus(0) catch |e| logger.panic("device detection failed: {}", .{e});
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

            const desc = DeviceDescriptor{ .vendor = vendor, .device = device };
            try devices.put(location, .{ .desc = desc, .class = class });

            const header_type = configRead(u8, location, 14);

            if (header_type & 0xF == 0x1) {
                // PCI-to-PCI bridge, let's read the next bus
                const next_bus = configRead(u8, location, 0x19);
                try detectBus(next_bus);
            }

            if (func == 0) {
                // if bit 7 is set, this is a multi-function device
                if (header_type >> 7 != 1) continue :slots;
            }
        }
    }
}

// CLASSIFICATION
// https://osdev.wiki/wiki/PCI#Class_Codes

pub const PrimaryClass = enum(u8) {
    unclassified = 0x0,
    mass_storage_controller = 0x1,
    network_controller = 0x2,
    display_controller = 0x3,
    multimedia_controller = 0x4,
    memory_controller = 0x5,
    bridge = 0x6,
    simple_communication_controller = 0x7,
    base_system_peripheral = 0x8,
    input_device_controller = 0x9,
    docking_station = 0xA,
    processor = 0xB,
    serial_bus_controller = 0xC,
    wireless_controller = 0xD,
    intelligent_controller = 0xE,
    satellite_communication_controller = 0xF,
    encryption_controller = 0x10,
    signal_processing_controller = 0x11,
    processing_accelerator = 0x12,
    non_essential_instrumentation = 0x13,
    co_processor = 0x40,
    unassigned = 0xFF,

    pub fn name(self: PrimaryClass) []const u8 {
        return switch (self) {
            .unclassified => "Unclassified",
            .mass_storage_controller => "Mass Storage Controller",
            .network_controller => "Network Controller",
            .display_controller => "Display Controller",
            .multimedia_controller => "Multimedia Controller",
            .memory_controller => "Memory Controller",
            .bridge => "Bridge",
            .simple_communication_controller => "Simple Communication Controller",
            .base_system_peripheral => "Base System Peripheral",
            .input_device_controller => "Input Device Controller",
            .docking_station => "Docking Station",
            .processor => "Processor",
            .serial_bus_controller => "Serial Bus Controller",
            .wireless_controller => "Wireless Controller",
            .intelligent_controller => "Intelligent Controller",
            .satellite_communication_controller => "Satellite Communication Controller",
            .encryption_controller => "Encryption Controller",
            .signal_processing_controller => "Signal Processing Controller",
            .processing_accelerator => "Processing Accelerator",
            .non_essential_instrumentation => "Non-Essential Instrumentation",
            .co_processor => "Co-Processor",
            .unassigned => "Unassigned Class",
        };
    }
};

pub const Class = union(PrimaryClass) {
    unclassified: Unclassified,
    mass_storage_controller: MassStorageController,
    network_controller: NetworkController,
    display_controller: DisplayController,
    multimedia_controller: MultimediaController,
    memory_controller: MemoryController,
    bridge: Bridge,
    simple_communication_controller: SimpleCommunicationController,
    base_system_peripheral: BaseSystemPeripheral,
    input_device_controller: InputDeviceController,
    docking_station: DockingStation,
    processor: Processor,
    serial_bus_controller: SerialBusController,
    wireless_controller: WirelessController,
    intelligent_controller: IntelligentController,
    satellite_communication_controller: SatelliteCommunicationController,
    encryption_controller: EncryptionController,
    signal_processing_controller: SignalProcessingController,
    processing_accelerator: void,
    non_essential_instrumentation: void,
    co_processor: void,
    unassigned: void,

    const Self = @This();

    pub fn parse(primary: u8, subclass: u8, interface: u8) ?Self {
        return switch (primary) {
            0x0 => .{ .unclassified = switch (subclass) {
                0x0 => .non_vga_compat,
                0x1 => .vga_compat,
                else => return null,
            } },
            0x1 => .{ .mass_storage_controller = MassStorageController.parse(subclass, interface) orelse return null },
            0x2 => .{ .network_controller = switch (subclass) {
                0x0 => .ethernet_controller,
                0x1 => .token_ring_controller,
                0x2 => .fddi_controller,
                0x3 => .atm_controller,
                0x4 => .isdn_controller,
                0x5 => .worldfip_controller,
                0x6 => .picmg_2_14_multi_computing_controller,
                0x7 => .infiniband_controller,
                0x8 => .fabric_controller,
                0x80 => .other,
                else => return null,
            } },
            0x3 => .{ .display_controller = DisplayController.parse(subclass, interface) orelse return null },
            0x4 => .{ .multimedia_controller = switch (subclass) {
                0x0 => .multimedia_video_controller,
                0x1 => .multimedia_audio_controller,
                0x2 => .computer_telephony_device,
                0x3 => .audio_device,
                0x80 => .other,
                else => return null,
            } },
            0x5 => .{ .memory_controller = switch (subclass) {
                0x0 => .ram_controller,
                0x1 => .flash_controller,
                0x80 => .other,
                else => return null,
            } },
            0x6 => .{ .bridge = Bridge.parse(subclass, interface) orelse return null },
            0x7 => .{ .simple_communication_controller = SimpleCommunicationController.parse(subclass, interface) orelse return null },
            0x8 => .{ .base_system_peripheral = BaseSystemPeripheral.parse(subclass, interface) orelse return null },
            0x9 => .{ .input_device_controller = InputDeviceController.parse(subclass, interface) orelse return null },
            0xA => .{ .docking_station = switch (subclass) {
                0x0 => .generic,
                0x80 => .other,
                else => return null,
            } },
            0xB => .{ .processor = switch (subclass) {
                0x0 => ._386,
                0x1 => ._486,
                0x2 => .pentium,
                0x3 => .pentium_pro,
                0x10 => .alpha,
                0x20 => .powerpc,
                0x30 => .mips,
                0x40 => .co_processor,
                0x80 => .other,
                else => return null,
            } },
            0xC => .{ .serial_bus_controller = SerialBusController.parse(subclass, interface) orelse return null },
            0xD => .{ .wireless_controller = switch (subclass) {
                0x0 => .irda_compatible_controller,
                0x1 => .consumer_ir_controller,
                0x10 => .rf_controller,
                0x11 => .bluetooth_controller,
                0x12 => .broadband_controller,
                0x20 => .ethernet_a_controller,
                0x21 => .ethernet_b_controller,
                0x80 => .other,
                else => return null,
            } },
            0xE => .{ .intelligent_controller = switch (subclass) {
                0x0 => .i20,
                else => return null,
            } },
            0xF => .{ .satellite_communication_controller = switch (subclass) {
                0x1 => .tv_controller,
                0x2 => .audio_controller,
                0x3 => .voice_controller,
                0x4 => .data_controller,
                else => return null,
            } },
            0x10 => .{ .encryption_controller = switch (subclass) {
                0x0 => .network_and_computing,
                0x10 => .entertainment,
                0x80 => .other,
                else => return null,
            } },
            0x11 => .{ .signal_processing_controller = switch (subclass) {
                0x0 => .dpio_modules,
                0x1 => .performance_counters,
                0x10 => .communication_synchronizer,
                0x20 => .signal_processing_management,
                0x80 => .other,
                else => return null,
            } },
            0x12 => .processing_accelerator,
            0x13 => .non_essential_instrumentation,
            0x40 => .co_processor,
            0xFF => .unassigned,
            else => null,
        };
    }

    pub fn format(self: Self, writer: *std.Io.Writer) !void {
        const tag = @as(PrimaryClass, self);
        switch (tag) {
            inline else => |t| {
                const tag_name = @tagName(t);

                const FieldType = @FieldType(Self, tag_name);
                if (FieldType == void) return writer.writeAll(comptime t.name());

                const field_value = @field(self, tag_name);
                return field_value.format(writer);
            },
        }
    }
};

// 0x0 - Unclassified

pub const Unclassified = enum {
    non_vga_compat,
    vga_compat,

    pub fn format(self: Unclassified, writer: *std.Io.Writer) !void {
        const name = switch (self) {
            .non_vga_compat => "Non-VGA-Compatible Unclassified Device",
            .vga_compat => "VGA-Compatible Unclassified Device",
        };

        try writer.writeAll(name);
    }
};

// 0x1 - Mass Storage Controller

pub const MassStorageController = union(enum) {
    scsi_bus_controller: void,
    ide_controller: struct {
        pci_native: bool,
        only_mode: bool,
        bus_mastering: bool,
    },
    floppy_disk_controller: void,
    ipi_bus_controller: void,
    raid_controller: void,
    ata_controller: struct { dma: enum { single, chained } },
    serial_ata_controller: struct { interface: enum { vendor_specific, ahci1_0, serial_storage_bus } },
    serial_attached_scsi_controller: struct { interface: enum { sas, serial_storage_bus } },
    non_volatile_memory_controller: struct { interface: enum { nvmhci, express } },
    other: void,

    pub fn parse(subclass: u8, interface: u8) ?MassStorageController {
        return switch (subclass) {
            0x0 => .scsi_bus_controller,
            0x1 => ide: {
                const first_half = interface & 0xF;
                if (first_half % 5 != 0) return null;
                const second_half = interface & 0xF0;
                if (second_half % 0x80 != 0) return null;

                break :ide .{
                    .ide_controller = .{
                        // 0x5/0xF is pci native
                        .pci_native = first_half % 0xA == 5,
                        // 0xA/0xF allows switching
                        .only_mode = first_half < 0xA,
                        .bus_mastering = second_half == 0x80,
                    },
                };
            },
            0x2 => .floppy_disk_controller,
            0x3 => .ipi_bus_controller,
            0x4 => .raid_controller,
            0x5 => .{ .ata_controller = .{
                .dma = switch (interface) {
                    0x20 => .single,
                    0x30 => .chained,
                    else => return null,
                },
            } },
            0x6 => .{ .serial_ata_controller = .{
                .interface = switch (interface) {
                    0x0 => .vendor_specific,
                    0x1 => .ahci1_0,
                    0x2 => .serial_storage_bus,
                    else => return null,
                },
            } },
            0x7 => .{ .serial_attached_scsi_controller = .{
                .interface = switch (interface) {
                    0x0 => .sas,
                    0x1 => .serial_storage_bus,
                    else => return null,
                },
            } },
            0x8 => .{ .non_volatile_memory_controller = .{
                .interface = switch (interface) {
                    0x1 => .nvmhci,
                    0x2 => .express,
                    else => return null,
                },
            } },
            0x80 => .other,
            else => null,
        };
    }

    pub fn format(self: MassStorageController, writer: *std.Io.Writer) !void {
        const name = switch (self) {
            .scsi_bus_controller => "SCSI Bus Controller",
            .ide_controller => "IDE Controller",
            .floppy_disk_controller => "Floppy Disk Controller",
            .ipi_bus_controller => "IPI Bus Controller",
            .raid_controller => "RAID Controller",
            .ata_controller => "ATA Controller",
            .serial_ata_controller => "Serial ATA Controller",
            .serial_attached_scsi_controller => "Serial Attached SCSI Controller",
            .non_volatile_memory_controller => "Non-Volatile Memory Controller",
            .other => "Other Mass Storage Controller",
        };

        try writer.writeAll(name);

        switch (self) {
            .ide_controller => |ide| {
                try writer.writeAll(" (");

                const mode = if (ide.pci_native)
                    "PCI Native Mode"
                else
                    "ISA Compatibility Mode";
                try writer.writeAll(mode);

                if (ide.only_mode)
                    try writer.writeAll(" only");

                if (ide.bus_mastering)
                    try writer.writeAll(", supports bus mastering");

                try writer.writeByte(')');
            },
            .ata_controller => |ata| {
                const dma = switch (ata.dma) {
                    .single => "Single",
                    .chained => "Chained",
                };
                try writer.print(" ({s} DMA)", .{dma});
            },
            .serial_ata_controller => |sata| {
                const interface = switch (sata.interface) {
                    .vendor_specific => "Vendor Specific",
                    .ahci1_0 => "AHCI 1.0",
                    .serial_storage_bus => "Serial Storage Bus",
                };
                try writer.print(" ({s} Interface)", .{interface});
            },
            .serial_attached_scsi_controller => |sas| {
                const interface = switch (sas.interface) {
                    .sas => "SAS",
                    .serial_storage_bus => "Serial Storage Bus",
                };
                try writer.print(" ({s} Interface)", .{interface});
            },
            .non_volatile_memory_controller => |nvm| {
                const interface = switch (nvm.interface) {
                    .nvmhci => "NVMHCI",
                    .express => "Express",
                };
                try writer.print(" ({s} Interface)", .{interface});
            },
            else => {},
        }
    }
};

// 0x2 - Network Controller

pub const NetworkController = enum {
    ethernet_controller,
    token_ring_controller,
    fddi_controller,
    atm_controller,
    isdn_controller,
    worldfip_controller,
    picmg_2_14_multi_computing_controller,
    infiniband_controller,
    fabric_controller,
    other,

    pub fn format(self: NetworkController, writer: *std.Io.Writer) !void {
        const name = switch (self) {
            .ethernet_controller => "Ethernet Controller",
            .token_ring_controller => "Token Ring Controller",
            .fddi_controller => "FDDI Controller",
            .atm_controller => "ATM Controller",
            .isdn_controller => "ISDN COntroller",
            .worldfip_controller => "WorldFip Controller",
            .picmg_2_14_multi_computing_controller => "PICMG 2.14 Multi Computing Controller",
            .infiniband_controller => "InfiniBand Network Controller",
            .fabric_controller => "Fabric Controller",
            .other => "Other Network Controller",
        };

        try writer.writeAll(name);
    }
};

// 0x3 - Display Controller

pub const DisplayController = union(enum) {
    vga_compatible: struct { typ: enum { vga, _8514_compatible } },
    xga: void,
    _3d: void,
    other: void,

    const Self = @This();

    pub fn parse(subclass: u8, interface: u8) ?Self {
        return switch (subclass) {
            0x0 => .{ .vga_compatible = .{
                .typ = switch (interface) {
                    0x0 => .vga,
                    0x1 => ._8514_compatible,
                    else => return null,
                },
            } },
            0x1 => .xga,
            0x2 => ._3d,
            0x80 => .other,
            else => null,
        };
    }

    pub fn format(self: Self, writer: *std.Io.Writer) !void {
        const name = switch (self) {
            .vga_compatible => |v| switch (v.typ) {
                .vga => "VGA Controller",
                ._8514_compatible => "8514-Compatible VGA Controller",
            },
            .xga => "XGA Controller",
            ._3d => "3D Controller",
            .other => "Other Display Controller",
        };

        try writer.writeAll(name);
    }
};

// 0x4 - Multimedia Controller

pub const MultimediaController = enum {
    multimedia_video_controller,
    multimedia_audio_controller,
    computer_telephony_device,
    audio_device,
    other,

    pub fn format(self: MultimediaController, writer: *std.Io.Writer) !void {
        const name = switch (self) {
            .multimedia_video_controller => "Multimedia Video Controller",
            .multimedia_audio_controller => "Multimedia Audio Controller",
            .computer_telephony_device => "Computer Telephony Device",
            .audio_device => "Audio Device",
            .other => "Other Multimedia Controller",
        };

        try writer.writeAll(name);
    }
};

// 0x5 - Memory Controller

pub const MemoryController = enum {
    ram_controller,
    flash_controller,
    other,

    pub fn format(self: MemoryController, writer: *std.Io.Writer) !void {
        const name = switch (self) {
            .ram_controller => "RAM Controller",
            .flash_controller => "Flash Controller",
            .other => "Other Memory Controller",
        };

        try writer.writeAll(name);
    }
};

// 0x6 - Bridge

pub const Bridge = union(enum) {
    host: void,
    isa: void,
    eisa: void,
    mca: void,
    pci_to_pci: struct { decode: enum { normal, subtractive } },
    pcmcia: void,
    nubus: void,
    cardbus: void,
    raceway: struct { mode: enum { transparent, endpoint } },
    pci_to_pci_semi_transparent: struct { bus: enum { primary, secondary } },
    infiniband_to_pci_host: void,
    other: void,

    pub fn parse(subclass: u8, interface: u8) ?Bridge {
        return switch (subclass) {
            0x0 => .host,
            0x1 => .isa,
            0x2 => .eisa,
            0x3 => .mca,
            0x4 => .{ .pci_to_pci = .{
                .decode = switch (interface) {
                    0x0 => .normal,
                    0x1 => .subtractive,
                    else => return null,
                },
            } },
            0x5 => .pcmcia,
            0x6 => .nubus,
            0x7 => .cardbus,
            0x8 => .{ .raceway = .{
                .mode = switch (interface) {
                    0x0 => .transparent,
                    0x1 => .endpoint,
                    else => return null,
                },
            } },
            0x9 => .{ .pci_to_pci_semi_transparent = .{
                .bus = switch (interface) {
                    0x40 => .primary,
                    0x80 => .secondary,
                    else => return null,
                },
            } },
            0x0A => .infiniband_to_pci_host,
            0x80 => .other,
            else => null,
        };
    }

    pub fn format(self: Bridge, writer: *std.Io.Writer) !void {
        const name = switch (self) {
            .host => "Host",
            .isa => "ISA",
            .eisa => "EISA",
            .mca => "MCA",
            .pci_to_pci => "PCI-to-PCI",
            .pcmcia => "PCMCIA",
            .nubus => "NuBus",
            .cardbus => "CardBus",
            .raceway => "RACEway",
            .pci_to_pci_semi_transparent => "PCI-to-PCI Semi-Transparent",
            .infiniband_to_pci_host => "InfiniBand-to-PCI Host",
            .other => "Other",
        };

        try writer.writeAll(name);
        try writer.writeAll(" Bridge");

        switch (self) {
            .pci_to_pci => |b| {
                const decode = switch (b.decode) {
                    .normal => "Normal",
                    .subtractive => "Subtractive",
                };
                try writer.print(" ({s} Decode)", .{decode});
            },
            .raceway => |b| {
                const mode = switch (b.mode) {
                    .transparent => "Transparent",
                    .endpoint => "Endpoint",
                };
                try writer.print(" ({s} Mode)", .{mode});
            },
            .pci_to_pci_semi_transparent => |b| {
                const bus = switch (b.bus) {
                    .primary => "Primary",
                    .secondary => "Secondary",
                };
                try writer.print(" ({s} bus towards host CPU)", .{bus});
            },
            else => {},
        }
    }
};

// 0x7 - Simple Communication Controller

pub const SimpleCommunicationController = union(enum) {
    serial: struct { interface: enum {
        _8250,
        _16450,
        _16550,
        _16650,
        _16750,
        _16850,
        _16950,
    } },
    parallel: struct { type: enum {
        standard,
        bidi,
        ecp_1_x_complicant,
        ieee_1284_controller,
        ieee_1284_target_device,
    } },
    multiport_serial: void,
    modem: struct { interface: enum {
        generic,
        _16450,
        _16550,
        _16650,
        _16750,
    } },
    gpib: void,
    smart_card: void,
    other: void,

    pub fn parse(subclass: u8, interface: u8) ?SimpleCommunicationController {
        return switch (subclass) {
            0x0 => .{ .serial = .{
                .interface = switch (interface) {
                    0x0 => ._8250,
                    0x1 => ._16450,
                    0x2 => ._16550,
                    0x3 => ._16650,
                    0x4 => ._16750,
                    0x5 => ._16850,
                    0x6 => ._16950,
                    else => return null,
                },
            } },
            0x1 => .{ .parallel = .{
                .type = switch (interface) {
                    0x0 => .standard,
                    0x1 => .bidi,
                    0x2 => .ecp_1_x_complicant,
                    0x3 => .ieee_1284_controller,
                    0xFE => .ieee_1284_target_device,
                    else => return null,
                },
            } },
            0x2 => .multiport_serial,
            0x3 => .{ .modem = .{
                .interface = switch (interface) {
                    0x0 => .generic,
                    0x1 => ._16450,
                    0x2 => ._16550,
                    0x3 => ._16650,
                    0x4 => ._16750,
                    else => return null,
                },
            } },
            0x4 => .gpib,
            0x5 => .smart_card,
            0x80 => .other,
            else => null,
        };
    }

    pub fn format(self: SimpleCommunicationController, writer: *std.Io.Writer) !void {
        switch (self) {
            .serial => |serial| try writer.print("{s}-Compatible Serial Controller", .{@tagName(serial.interface)[1..]}),
            .parallel => |parallel| {
                const name = switch (parallel.type) {
                    .standard => "Standard Parallel Port",
                    .bidi => "Bi-Directional Parallel Port",
                    .ecp_1_x_complicant => "ECP 1.x Compliant Parallel Port",
                    .ieee_1284_controller => "IEEE 1284 Parallel Controller",
                    .ieee_1284_target_device => "IEEE 1284 Parallel Target Device",
                };
                try writer.writeAll(name);
            },
            .modem => |modem| if (modem.interface == .generic) {
                try writer.writeAll("Generic Modem");
            } else {
                try writer.print("Hayes {s}-Compatible Modem", .{@tagName(modem.interface)[1..]});
            },
            else => {
                const name = switch (self) {
                    .multiport_serial => "Multiport Serial Controller",
                    .gpib => "IEEE 488.1/2 (GPIB) Controller",
                    .smart_card => "Smart Card Controller",
                    .other => "Other Simple Communication Controller",
                    else => unreachable,
                };

                try writer.writeAll(name);
            },
        }
    }
};

// 0x8 - Base System Peripheral

pub const BaseSystemPeripheral = union(enum) {
    pic: struct { type: enum { generic_8259, isa, eisa, io_apic, iox_apic } },
    dma_controller: struct { type: enum { generic_8237, isa, eisa } },
    timer: struct { type: enum { generic_8254, isa, eisa, hpet } },
    rtc_controller: struct { type: enum { generic, isa } },
    pci_hot_plug_controller: void,
    sd_host_controller: void,
    iommu: void,
    other: void,

    pub fn parse(subclass: u8, interface: u8) ?BaseSystemPeripheral {
        return switch (subclass) {
            0x0 => .{ .pic = .{
                .type = switch (interface) {
                    0x0 => .generic_8259,
                    0x1 => .isa,
                    0x2 => .eisa,
                    0x10 => .io_apic,
                    0x20 => .iox_apic,
                    else => return null,
                },
            } },
            0x1 => .{ .dma_controller = .{
                .type = switch (interface) {
                    0x0 => .generic_8237,
                    0x1 => .isa,
                    0x2 => .eisa,
                    else => return null,
                },
            } },
            0x2 => .{ .timer = .{
                .type = switch (interface) {
                    0x0 => .generic_8254,
                    0x1 => .isa,
                    0x2 => .eisa,
                    0x3 => .hpet,
                    else => return null,
                },
            } },
            0x3 => .{ .rtc_controller = .{
                .type = switch (interface) {
                    0x0 => .generic,
                    0x1 => .isa,
                    else => return null,
                },
            } },
            0x4 => .pci_hot_plug_controller,
            0x5 => .sd_host_controller,
            0x6 => .iommu,
            0x80 => .other,
            else => null,
        };
    }

    pub fn format(self: BaseSystemPeripheral, writer: *std.Io.Writer) !void {
        switch (self) {
            .pic => |pic| {
                const name = switch (pic.type) {
                    .generic_8259 => "Generic 8259-Compatible PIC",
                    .isa => "ISA-Compatible PIC",
                    .eisa => "EISA-Compatible PIC",
                    .io_apic => "I/O APIC",
                    .iox_apic => "I/O(x) APIC",
                };
                try writer.writeAll(name);
            },
            .dma_controller => |dma| {
                const typ = switch (dma.type) {
                    .generic_8237 => "Generic 8237",
                    .isa => "ISA",
                    .eisa => "EISA",
                };
                try writer.print("{s}-Compatible DMA Controller", .{typ});
            },
            .timer => |timer| {
                const typ = switch (timer.type) {
                    .generic_8254 => "Generic 8254-Compatible",
                    .isa => "ISA-Compatible",
                    .eisa => "EISA-Compatible",
                    .hpet => "High Precision Event",
                };
                try writer.print("{s} Timer", .{typ});
            },
            .rtc_controller => |rtc| {
                const typ = switch (rtc.type) {
                    .generic => "Generic",
                    .isa => "ISA-Compatible",
                };
                try writer.print("{s} RTC Controller", .{typ});
            },
            else => {
                const name = switch (self) {
                    .pci_hot_plug_controller => "PCI Hot-Plug Controller",
                    .sd_host_controller => "SD Host Controller",
                    .iommu => "IOMMU",
                    .other => "Other Base System Peripheral",
                    else => unreachable,
                };

                try writer.writeAll(name);
            },
        }
    }
};

// 0x9 - Input Device Controller

pub const InputDeviceController = union(enum) {
    keyboard_controller: void,
    digitizer_pen: void,
    mouse_controller: void,
    scanner_controller: void,
    gameport_controller: struct { type: enum { generic, extended } },
    other: void,

    pub fn parse(subclass: u8, interface: u8) ?InputDeviceController {
        return switch (subclass) {
            0x0 => .keyboard_controller,
            0x1 => .digitizer_pen,
            0x2 => .mouse_controller,
            0x3 => .scanner_controller,
            0x4 => .{ .gameport_controller = .{
                .type = switch (interface) {
                    0x0 => .generic,
                    0x10 => .extended,
                    else => return null,
                },
            } },
            0x80 => .other,
            else => null,
        };
    }

    pub fn format(self: InputDeviceController, writer: *std.Io.Writer) !void {
        const name = switch (self) {
            .keyboard_controller => "Keyboard Controller",
            .digitizer_pen => "Digitizer Pen",
            .mouse_controller => "Mouse Controller",
            .scanner_controller => "Scanner Controller",
            .gameport_controller => "Gameport Controller",
            .other => "Other Input Device Controller",
        };

        try writer.writeAll(name);

        if (self == .gameport_controller) {
            const typ = switch (self.gameport_controller.type) {
                .generic => "Generic",
                .extended => "Extended",
            };
            try writer.print(" ({s})", .{typ});
        }
    }
};

// 0xA - Docking Station

pub const DockingStation = enum {
    generic,
    other,

    pub fn format(self: DockingStation, writer: *std.Io.Writer) !void {
        const name = switch (self) {
            .generic => "Generic Docking Station",
            .other => "Other Docking Station",
        };

        try writer.writeAll(name);
    }
};

// 0xB - Processor

pub const Processor = enum {
    _386,
    _486,
    pentium,
    pentium_pro,
    alpha,
    powerpc,
    mips,
    co_processor,
    other,

    pub fn format(self: Processor, writer: *std.Io.Writer) !void {
        const name = switch (self) {
            ._386 => "386 Processor",
            ._486 => "486 Processor",
            .pentium => "Pentium Processor",
            .pentium_pro => "Pentium Pro Processor",
            .alpha => "Alpha Processor",
            .powerpc => "PowerPC Processor",
            .mips => "MIPS Processor",
            .co_processor => "Co-Processor (Processor)",
            .other => "Other Processor",
        };

        try writer.writeAll(name);
    }
};

// 0xC - Serial Bus Controller

pub const SerialBusController = union(enum) {
    firewire: struct { interface: enum { generic, ohci } },
    access_bus: void,
    ssa: void,
    usb: struct { interface: enum {
        uhci,
        ohci,
        ehci,
        xhci,
        unspecified,
        device,
    } },
    fibre_channel: void,
    smbus: void,
    infiniband: void,
    ipmi_interface: struct { interface: enum {
        smic,
        keyboard_controller_style,
        block_transfer,
    } },
    sercos_interface: void,
    canbus: void,
    other: void,

    pub fn parse(subclass: u8, interface: u8) ?SerialBusController {
        return switch (subclass) {
            0x0 => .{ .firewire = .{
                .interface = switch (interface) {
                    0x0 => .generic,
                    0x10 => .ohci,
                    else => return null,
                },
            } },
            0x1 => .access_bus,
            0x2 => .ssa,
            0x3 => .{ .usb = .{
                .interface = switch (interface) {
                    0x0 => .uhci,
                    0x10 => .ohci,
                    0x20 => .ehci,
                    0x30 => .xhci,
                    0x80 => .unspecified,
                    0xFE => .device,
                    else => return null,
                },
            } },
            0x4 => .fibre_channel,
            0x5 => .smbus,
            0x6 => .infiniband,
            0x7 => .{ .ipmi_interface = .{
                .interface = switch (interface) {
                    0x0 => .smic,
                    0x1 => .keyboard_controller_style,
                    0x2 => .block_transfer,
                    else => return null,
                },
            } },
            0x8 => .sercos_interface,
            0x9 => .canbus,
            0x80 => .other,
            else => null,
        };
    }

    pub fn format(self: SerialBusController, writer: *std.Io.Writer) !void {
        if (self == .firewire) {
            const interface = switch (self.firewire.interface) {
                .generic => "Generic",
                .ohci => "OHCI",
            };
            try writer.print("{s} Firewire Controller", .{interface});

            return;
        } else if (self == .usb) {
            if (self.usb.interface == .device) {
                try writer.writeAll("USB Device");
            } else {
                const interface = switch (self.usb.interface) {
                    .uhci => "UHCI",
                    .ohci => "OHCI",
                    .ehci => "EHCI",
                    .xhci => "XHCI",
                    .unspecified => "Unspecified",
                    .device => unreachable,
                };
                try writer.print("{s} USB Controller", .{interface});
            }

            return;
        } else if (self == .ipmi_interface) {
            const interface = switch (self.ipmi_interface.interface) {
                .smic => "SMIC",
                .keyboard_controller_style => "Keyboard Controller Style",
                .block_transfer => "Block Transfer",
            };
            try writer.print("IPMI {s} Interface", .{interface});

            return;
        }

        const name = switch (self) {
            .access_bus => "ACCESS Bus Controller",
            .ssa => "SSA",
            .fibre_channel => "Fibre Channel",
            .smbus => "SMBus Controller",
            .infiniband => "InfiniBand Controller",
            .sercos_interface => "SERCOS Interface",
            .canbus => "CANbus Controller",
            .other => "Other Serial Bus Controller",
            else => unreachable,
        };

        try writer.writeAll(name);
    }
};

// 0xD - Wireless Controller

pub const WirelessController = enum {
    irda_compatible_controller,
    consumer_ir_controller,
    rf_controller,
    bluetooth_controller,
    broadband_controller,
    ethernet_a_controller,
    ethernet_b_controller,
    other,

    pub fn format(self: WirelessController, writer: *std.Io.Writer) !void {
        const name = switch (self) {
            .irda_compatible_controller => "iRDA Compatible Controller",
            .consumer_ir_controller => "Consumer IR Controller",
            .rf_controller => "RF Controller",
            .bluetooth_controller => "Bluetooth Controller",
            .broadband_controller => "Broadband Controller",
            .ethernet_a_controller => "Ethernet Controller (802.1a)",
            .ethernet_b_controller => "Ethernet Controller (802.1b)",
            .other => "Other Wireless Controller",
        };

        try writer.writeAll(name);
    }
};

// 0xE - Intelligent Controller

pub const IntelligentController = enum {
    i20,

    pub fn format(self: IntelligentController, writer: *std.Io.Writer) !void {
        const name = switch (self) {
            .i20 => "I20 Intelligent Controller",
        };

        try writer.writeAll(name);
    }
};

// 0xF - Satellite Communication Controller

pub const SatelliteCommunicationController = enum {
    tv_controller,
    audio_controller,
    voice_controller,
    data_controller,

    pub fn format(self: SatelliteCommunicationController, writer: *std.Io.Writer) !void {
        const name = switch (self) {
            .tv_controller => "Satellite TV Controller",
            .audio_controller => "Satellite Audio Controller",
            .voice_controller => "Satellite Voice Controller",
            .data_controller => "Satellite Data Controller",
        };

        try writer.writeAll(name);
    }
};

// 0x10 - Encryption Controller

pub const EncryptionController = enum {
    network_and_computing,
    entertainment,
    other,

    pub fn format(self: EncryptionController, writer: *std.Io.Writer) !void {
        const name = switch (self) {
            .network_and_computing => "Network and Computing Encryption / Decryption Controller",
            .entertainment => "Entertainment Encryption / Decryption Controller",
            .other => "Other Encryption Controller",
        };

        try writer.writeAll(name);
    }
};

// 0x11 - Signal Processing Controller

pub const SignalProcessingController = enum {
    dpio_modules,
    performance_counters,
    communication_synchronizer,
    signal_processing_management,
    other,

    pub fn format(self: SignalProcessingController, writer: *std.Io.Writer) !void {
        const name = switch (self) {
            .dpio_modules => "DPIO Modules",
            .performance_counters => "Performance Counters",
            .communication_synchronizer => "Communication Synchronizer",
            .signal_processing_management => "Signal Processing Management",
            .other => "Other Signal Processing Controller",
        };

        try writer.writeAll(name);
    }
};
