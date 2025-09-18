const builtin = @import("builtin");
const std = @import("std");

const common_magic: [2]u64 = .{ 0xc7b1dd30df4c8b88, 0x0a82e883a194f07b };

// REVISION

export const revision: [3]u64 linksection(".requests") =
    .{ 0xf9562b2d5c95a6c8, 0x6a7b384944536bdc, 3 };

// MARKERS

export const requests_start: [4]u64 linksection(".requests_start") =
    .{ 0xf6b8f4b39de7d1ae, 0xfab91a6940fcb9cf, 0x785c6ed015d3e316, 0x181e920a7852b9d9 };

export const requests_end: [2]u64 linksection(".requests_end") =
    .{ 0xadc0e0531bb10d03, 0x9572709f31764c62 };

// REQUEST FORMAT

pub fn Request(comptime magic: [2]u64, comptime Response: type) type {
    const res_info = @typeInfo(Response);
    comptime var ResT: type = *const Response;
    if (res_info == .optional) ResT = ?ResT;

    return extern struct {
        id: [4]u64 = common_magic ++ magic,
        revision: u64 = 0,
        response: ResT = if (res_info == .optional) null else undefined,
    };
}

// BOOTLOADER INFO

pub export var bootldr linksection(".requests") =
    Request(.{ 0xf55038d8e2a1202f, 0x279426fcf5f59740 }, BootloaderInfoResponse){};

pub const BootloaderInfoResponse = extern struct {
    revision: u64 = 0,
    name: [*:0]const u8,
    version: [*:0]const u8,
};

// FRAMEBUFFER

pub export var fb linksection(".requests") =
    Request(.{ 0x9d5827dcd881dd75, 0xa3148604f6fab11b }, FramebufferResponse){ .revision = 1 };

pub const FramebufferResponse = extern struct {
    revision: u64,
    count: u64,
    entries: [*]const *const Framebuffer,
};

pub const Framebuffer = extern struct {
    ptr: [*]u8,
    width: u64,
    height: u64,
    pitch: u64,
    bpp: u16,
    memory_model: MemoryModel,
    red_mask_size: u8,
    red_mask_shift: u8,
    green_mask_size: u8,
    green_mask_shift: u8,
    blue_mask_size: u8,
    blue_mask_shift: u8,
    unused: [7]u8,
    edid_size: u64,
    edid: ?[*]const u8,
    // revision 1
    mode_count: u64,
    modes: [*]const *const VideoMode,

    pub const MemoryModel = enum(u8) { rgb = 1 };

    pub const VideoMode = extern struct {
        pitch: u64,
        width: u64,
        height: u64,
        bpp: u16,
        memory_model: MemoryModel,
        red_mask_size: u8,
        red_mask_shift: u8,
        green_mask_size: u8,
        green_mask_shift: u8,
        blue_mask_size: u8,
        blue_mask_shift: u8,
    };
};

// MEMORY MAP

pub export var mmap linksection(".requests") =
    Request(.{ 0x67cf3d9d378a806f, 0xe304acdfc50c3c62 }, MemoryMapResponse){};

pub const MemoryMapResponse = extern struct {
    revision: u64,
    count: u64,
    entries: [*]const *MemoryMapEntry,
};

pub const MemoryMapEntry = extern struct {
    ptr: [*]u8,
    len: u64,
    type: Type,

    pub const Type = enum(u64) {
        usable = 0,
        reserved = 1,
        acpi_reclaimable = 2,
        acpi_nvs = 3,
        bad_memory = 4,
        bootloader_reclaimable = 5,
        kernel_and_modules = 6,
        framebuffer = 7,
    };
};

// HHDM LOCATION

pub export var hhdm linksection(".requests") =
    Request(.{ 0x48dcf1cb8ad2b852, 0x63984e959a98244b }, HhdmResponse){};

pub const HhdmResponse = extern struct {
    revision: u64,
    offset: u64,
};

pub inline fn convertPointer(ptr: anytype) @TypeOf(ptr) {
    if (@typeInfo(@TypeOf(ptr)) != .pointer)
        @compileError("convertPointer called on non-pointer type");

    const addr = @intFromPtr(ptr) | hhdm.response.offset;
    return @ptrFromInt(addr);
}

// PAGING MODE

pub export var paging_mode linksection(".requests") = PagingModeRequest{};

pub const PagingModeRequest = extern struct {
    id: [4]u64 = common_magic ++ .{ 0x95c1a0edab0944cb, 0xa4e5cb3842f7488a },
    revision: u64 = 0,
    response: *const PagingModeResponse = undefined,
    mode: u64 = 1, // request 57-bit mode
};

pub const PagingModeResponse = extern struct {
    revision: u64,
    mode: u64,
};

// SMBIOS

pub export var smbios linksection(".requests") =
    Request(.{ 0x9e9046f11e095391, 0xaa4a520fefbde5ee }, SmbiosResponse){};

pub const SmbiosResponse = extern struct {
    revision: u64,
    entry_32: *const void,
    entry_64: *const void,
};

// KERNEL ADDRESS

pub export var kaddr linksection(".requests") =
    Request(.{ 0x71ba76863cc55f63, 0xb2644a48c516a487 }, KernelAddressResponse){};

pub const KernelAddressResponse = extern struct {
    revision: u64,
    physical: u64,
    virtual: u64,
};

// KERNEL FILE

pub export var kfile linksection(".requests") =
    Request(.{ 0xad97e90e83f1ed67, 0x31eb5d1c5ff23b69 }, KernelFileResponse){};

pub const KernelFileResponse = extern struct {
    revision: u64,
    file: *const File,
};

pub const Uuid = extern struct { a: u32, b: u16, c: u16, d: [8]u8 };

pub const MediaType = enum(u32) { generic = 0, optical = 1, tftp = 2 };

pub const File = extern struct {
    revision: u64,
    address: u64,
    size: u64,
    path: [*:0]const u8,
    cmdline: [*:0]const u8,
    media_type: MediaType,
    unused: u32,
    tftp_ip: u32,
    tftp_port: u32,
    partition_index: u32,
    mbr_disk_id: u32,
    gpt_disk_uuid: Uuid,
    gpt_part_uuid: Uuid,
    part_uuid: Uuid,
};

// MODULES

pub export var modules linksection(".requests") =
    Request(.{ 0x3e7e279702be32af, 0xca1c4f3bd1280cee }, ModulesResponse){};

pub const ModulesResponse = extern struct {
    revision: u64,
    module_count: u64,
    modules: [*]const *const File,
};

// RSDP

const Rsdp = @import("acpi.zig").Rsdp;

pub export var rsdp linksection(".requests") =
    Request(.{ 0xc5e77b6b397e7b43, 0x27637845accdcf3c }, RsdpResponse){};

pub const RsdpResponse = extern struct {
    revision: u64,
    ptr: *Rsdp,
};

// MULTI-PROCESSOR INFORMATION

pub export var cpus linksection(".requests") = CpusRequest{};

pub const CpusRequest = extern struct {
    id: [4]u64 = common_magic ++ .{ 0x95a67b819a1b857e, 0xa0b61b723b6a73e0 },
    revision: u64 = 0,
    response: *const CpusResponse = undefined,
    flags: u64 = 1, // request x2APIC support
};

pub const CpusResponse = extern struct {
    revision: u64,
    flags: u32,
    bsp_lapic_id: u32,
    count: u64,
    cpus: [*]const *Cpu,
};

pub const CpuEntry = *const fn (*Cpu) callconv(.c) noreturn;

pub const Cpu = extern struct {
    acpi_id: u32,
    lapic_id: u32,
    reserved: u64,
    goto_addr: CpuEntry,
    index: u64,

    pub inline fn jump(cpu: *Cpu, entry: CpuEntry) void {
        @atomicStore(CpuEntry, &cpu.goto_addr, entry, .seq_cst);
    }
};
