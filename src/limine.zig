const builtin = @import("builtin");
const std = @import("std");

const common_magic: [2]u64 = .{ 0xc7b1dd30df4c8b88, 0x0a82e883a194f07b };

// REVISION

export const revision: [3]u64 linksection(".requests") =
    .{ 0xf9562b2d5c95a6c8, 0x6a7b384944536bdc, 2 };

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

pub inline fn bootldrName() []const u8 {
    return std.mem.span(bootldr.response.name);
}

// FRAMEBUFFER

pub export var fb linksection(".requests") =
    Request(.{ 0x9d5827dcd881dd75, 0xa3148604f6fab11b }, FramebufferResponse){};

pub const FramebufferResponse = extern struct {
    revision: u64,
    count: u64,
    entries: [*]const *const Framebuffer,
};

const Color = @import("tty.zig").Color;

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

    pub fn defaultVideoMode(self: Framebuffer) VideoMode {
        return .{
            .pitch = self.pitch,
            .width = self.width,
            .height = self.height,
            .bpp = self.bpp,
            .memory_model = self.memory_model,
            .red_mask_size = self.red_mask_size,
            .red_mask_shift = self.red_mask_shift,
            .green_mask_size = self.green_mask_size,
            .green_mask_shift = self.green_mask_shift,
            .blue_mask_size = self.blue_mask_size,
            .blue_mask_shift = self.blue_mask_shift,
        };
    }
};

// MEMORY MAP

pub export var mmap linksection(".requests") =
    Request(.{ 0x67cf3d9d378a806f, 0xe304acdfc50c3c62 }, MMapResponse){};

pub const MMapResponse = extern struct {
    revision: u64,
    count: u64,
    entries: [*]const *MMapEntry,
};

pub const MMapEntry = extern struct {
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
    Request(.{ 0x48dcf1cb8ad2b852, 0x63984e959a98244b }, HHDMResponse){};

pub const HHDMResponse = extern struct {
    revision: u64,
    offset: u64,
};

pub inline fn convertPointer(ptr: anytype) @TypeOf(ptr) {
    if (@typeInfo(@TypeOf(ptr)) != .pointer)
        @compileError("convertPointer called on non-pointer type");

    const addr = @intFromPtr(ptr) | hhdm.response.offset;
    return @ptrFromInt(addr);
}

// SMBIOS

pub export var smbios linksection(".requests") =
    Request(.{ 0x9e9046f11e095391, 0xaa4a520fefbde5ee }, SMBIOSResponse){};

pub const SMBIOSResponse = extern struct {
    revision: u64,
    entry_32: *const void,
    entry_64: *const void,
};

// DEVICE TREE BLOB

pub export var dtb linksection(".requests") =
    Request(.{ 0xb40ddb48fb54bac7, 0x545081493f81ffb7 }, ?DeviceTreeResponse){};

pub const DeviceTreeResponse = extern struct {
    revision: u64,
    pointer: ?*const void,
};

// EFI SYSTEM TABLE

pub export var efi_system_table linksection(".requests") =
    Request(.{ 0x5ceba5163eaaf6d6, 0x0a6981610cf65fcc }, EFISystemTableResponse){};

pub const EFISystemTableResponse = extern struct {
    revision: u64,
    ptr: *std.os.uefi.tables.SystemTable,
};

// EFI MEMORY MAP

const EFIMemoryDesc = std.os.uefi.tables.MemoryDescriptor;

pub export var efi_mmap linksection(".requests") =
    Request(.{ 0x7df62a431d6872d5, 0xa4fcdfb3e57306c8 }, EFIMMapResponse){};

pub const EFIMMapResponse = extern struct {
    revision: u64,
    mmap: u64,
    mmap_size: u64,
    desc_size: u64,
    desc_version: u64,
};

pub const EFIMMapIterator = struct {
    addr: u64 = 0,

    pub fn next(self: *EFIMMapIterator) ?*EFIMemoryDesc {
        if (self.addr >= (efi_mmap.response.mmap + efi_mmap.response.mmap_size)) {
            return null;
        } else if (self.addr == 0) {
            self.addr = efi_mmap.response.mmap;
        }

        const desc: *EFIMemoryDesc = @ptrFromInt(self.addr);
        self.addr += efi_mmap.response.desc_size;
        return desc;
    }
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
    address: *const void,
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

pub inline fn cmdline() []const u8 {
    return std.mem.span(kfile.response.file.cmdline);
}

pub inline fn kstart() usize {
    return @intFromPtr(kfile.response.file.address);
}
pub inline fn ksize() usize {
    return kfile.response.file.size;
}
pub inline fn kend() usize {
    return kstart() + ksize();
}

// KERNEL ADDRESS

pub export var kaddr linksection(".requests") =
    Request(.{ 0x71ba76863cc55f63, 0xb2644a48c516a487 }, KernelAddressResponse){};

pub const KernelAddressResponse = extern struct {
    revision: u64,
    physical: u64,
    virtual: u64,
};

// THREADS (multiprocessor info)

pub export var cpus linksection(".requests") = CPUsRequest{};

pub const CPUsRequest = extern struct {
    id: [4]u64 = common_magic ++ .{ 0x95a67b819a1b857e, 0xa0b61b723b6a73e0 },
    revision: u64 = 0,
    response: *const CPUsResponse = undefined,
    flags: u64 = 0,
};

pub const CPUsResponse = switch (builtin.cpu.arch) {
    .riscv64 => CPUsResponseRiscV64,
    else => extern struct {
        revision: u64,
        flags: u32,
        bsp_id: u32,
        count: u64,
        cpus: [*]const *CPU,
    },
};

pub const CPU = switch (builtin.cpu.arch) {
    .x86_64 => CPUX86,
    .aarch64 => CPUAArch64,
    .riscv64 => CPURiscV64,
    else => unreachable,
};

pub const CPUEntry = *const fn (*CPU) callconv(.c) noreturn;

pub inline fn jumpCPU(cpu: *CPU, entry: CPUEntry) void {
    @atomicStore(CPUEntry, &cpu.goto_addr, entry, .seq_cst);
}

// MP: x86-64

const CPUX86 = extern struct {
    acpi_id: u32,
    id: u32,
    reserved: u64,
    goto_addr: CPUEntry,
    extra: u64,
};

// MP: aarch64

const CPUAArch64 = extern struct {
    acpi_id: u32,
    reserved1: u32,
    id: u64,
    reserved: u64,
    goto_addr: CPUEntry,
    extra: u64,
};

// MP: riscv64

const CPUsResponseRiscV64 = extern struct {
    revision: u64,
    flags: u64,
    bsp_id: u64,
    count: u64,
    cpus: [*]const *CPU,
};

const CPURiscV64 = extern struct {
    acpi_id: u64,
    id: u64,
    reserved: u64,
    goto_addr: CPUEntry,
    extra: u64,
};
