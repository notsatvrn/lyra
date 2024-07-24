// HEADER

const magic: u32 = 0x1BADB002;
const flags: u32 = (1 << 0) | (1 << 1); // align loaded modules to 4KiB, get a memory map

pub const Header = extern struct {
    magic: u32 = magic,
    flags: u32 = flags,
    checksum: u32 = ~(magic +% flags) +% 1,
};

// RESPONSE

pub const info_magic: u32 = 0x2BADB002;

pub const BootInfo = packed struct {
    flags: u32,
    // Addresses of the lower and upper memory sections.
    // Present if flags[0] is set.
    mem_lower: u32,
    mem_upper: u32,
    // The boot drive represented as a 4-byte integer.
    // MSB = BIOS drive ID, other bytes are partition levels.
    // Present if flags[1] is set.
    boot_device: u32,
    // Address of the kernel command-line arguments.
    // The data itself is represented as a null-terminated string.
    // Present if flags[2] is set.
    cmdline: u32,
    // Module list count and address.
    // Present if flags[3] is set.
    mods_count: u32,
    mods_addr: u32,
    // If flags[4] is set, will be nlist.
    // If flags[5] is set, will be shdr.
    sym: Symbols,
    // Present if flags[6] is set.
    mmap_length: u32,
    mmap_addr: u32,
    // Present if flags[7] is set.
    drives_length: u32,
    drives_addr: u32,
    // Address of the ROM configuration table returned by the BIOS.
    // Present if flags[8] is set.
    config_table: u32,
    // Address of the boot loader name.
    // The data itself is represented as a null-terminated string.
    // Present if flags[9] is set.
    boot_loader_name: u32,
    // Address of the APM table.
    // Present if flags[10] is set.
    apm_table: u32,
};

// BOOT DEVICE

pub const BootDevice = struct {
    drive: u8,
    parts: [3]u8,
};

// SYMBOLS

pub const Symbols = packed union {
    nlist: packed struct {
        tabsize: u32,
        strsize: u32,
        addr: u32,
        _reserved: u32,
    },
    shdr: packed struct {
        num: u32,
        size: u32,
        addr: u32,
        shndx: u32,
    },
};

// MODULES

pub const Module = packed struct {};

// MEMORY MAP

pub const RawEntry = extern struct {
    size: u32,
    addr: u64,
    len: u64,
    typ: u32,
};

// DRIVES

pub const DriveMode = enum(u8) { chs, lba };

pub const Drive = packed struct {
    size: u32,

    number: u8,
    mode: DriveMode,

    cylinders: u16,
    heads: u8,
    sectors: u8,
};

// APM TABLE

pub const APMTable = packed struct {
    version: u16,
    cseg: u16,
    offset: u32,
    cseg_16: u16,
    dseg: u16,
    flags: u16,
    cseg_len: u16,
    cseg_16_len: u16,
    dseg_len: u16,
};
