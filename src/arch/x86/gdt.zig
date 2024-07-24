// https://wiki.osdev.org/Global_Descriptor_Table
//
// Original code from Andrea Orru's Zen kernel project (licensed under BSD-3-Clause)
// https://github.com/AndreaOrru/zen/blob/master/kernel/gdt.zig

// GDT segment selectors.
pub const KERNEL_CODE = @as(u16, 0x08);
pub const KERNEL_DATA = @as(u16, 0x10);
pub const USER_CODE = @as(u16, 0x18);
pub const USER_DATA = @as(u16, 0x20);
pub const TSS_DESC = @as(u16, 0x28);

// Privilege level of segment selector.
pub const KERNEL_RPL = 0b00;
pub const USER_RPL = 0b11;

// Access byte values.
const KERNEL = 0x90;
const USER = 0xF0;
const CODE = 0x0A;
const DATA = 0x02;
const TSS_ACCESS = 0x89;

// Segment flags.
const PROTECTED = (1 << 2);
const BLOCKS_4K = (1 << 3);

// Structure representing an entry in the GDT.
const GDTEntry = packed struct {
    limit_lo: u16,
    base_lo: u16,
    base_mid: u8,
    access: u8,
    limit_hi: u4,
    flags: u4,
    base_hi: u8,

    ////
    // Generate a GDT entry structure.
    //
    // Arguments:
    //     base: Beginning of the segment.
    //     limit: Size of the segment.
    //     access: Access byte.
    //     flags: Segment flags.
    //
    fn init(base: u32, limit: u20, access: u8, flags: u4) GDTEntry {
        return .{
            .base_lo = @truncate(base),
            .base_mid = @truncate(base >> 16),
            .base_hi = @truncate(base >> 24),

            .limit_lo = @truncate(limit),
            .limit_hi = @truncate(limit >> 16),

            .access = access,
            .flags = flags,
        };
    }
};

// GDT descriptor register.
const GDTRegister = packed struct {
    limit: u16,
    base: u32,
};

// Task State Segment.
const TSS = extern struct {
    unused1: u32,
    esp0: u32, // Stack to use when coming to ring 0 from ring > 0.
    ss0: u32, // Segment to use when coming to ring 0 from ring > 0.
    unused2: [22]u32,
    unused3: u16,
    iomap_base: u16, // Base of the IO bitmap.
};

comptime {
    @import("std").debug.assert(@sizeOf(TSS) == 104);
}

// Fill in the GDT.
var gdt align(4) = [_]GDTEntry{
    GDTEntry.init(0, 0, 0, 0),
    GDTEntry.init(0, 0xFFFFF, KERNEL | CODE, PROTECTED | BLOCKS_4K),
    GDTEntry.init(0, 0xFFFFF, KERNEL | DATA, PROTECTED | BLOCKS_4K),
    GDTEntry.init(0, 0xFFFFF, USER | CODE, PROTECTED | BLOCKS_4K),
    GDTEntry.init(0, 0xFFFFF, USER | DATA, PROTECTED | BLOCKS_4K),
    GDTEntry.init(0, 0, 0, 0), // TSS (fill in at runtime).
};

// GDT descriptor register pointing at the GDT.
var gdtr = GDTRegister{
    .limit = @truncate(@sizeOf(@TypeOf(gdt))),
    .base = undefined,
};

// Instance of the Task State Segment.
var tss = TSS{
    .unused1 = 0,
    .esp0 = undefined,
    .ss0 = KERNEL_DATA,
    .unused2 = .{0} ** 22,
    .unused3 = 0,
    .iomap_base = @sizeOf(TSS),
};

////
// Set the kernel stack to use when interrupting user mode.
//
// Arguments:
//     esp0: Stack for Ring 0.
//
pub fn setKernelStack(esp0: usize) void {
    tss.esp0 = esp0;
}

comptime {
    asm (
        \\.intel_syntax noprefix
        \\.text
        \\loadGDT:
        \\  mov eax, [esp + 4]  // Fetch the gdtr parameter.
        \\  lgdt [eax]          // Load the new GDT.
        \\
        \\reloadSegments:
        \\  // Reload data segments (GDT entry 2: kernel data).
        \\  mov ax, 0x10
        \\  mov ds, ax
        \\  mov es, ax
        \\  mov fs, ax
        \\  mov gs, ax
        \\  mov ss, ax
        \\
        \\  // Reload code segment (GDT entry 1: kernel code).
        \\.att_syntax prefix
        \\  ljmp $0x08, $1f
        \\1: ret
    );
}

////
// Load the GDT into the system registers (defined in assembly).
//
// Arguments:
//     gdtr: Pointer to the GDTR.
//
extern fn loadGDT(gdtr: *const GDTRegister) void;

// Reload the GDT segment registers.
pub extern fn reloadSegments() void;

////
// Initialize the Global Descriptor Table.
//
pub fn init() void {
    // Initialize TSS.
    const tss_entry = GDTEntry.init(@intFromPtr(&tss), @sizeOf(TSS) - 1, TSS_ACCESS, PROTECTED);
    gdt[TSS_DESC / @sizeOf(GDTEntry)] = tss_entry;

    // Initialize GDT.
    gdtr.base = @intFromPtr(&gdt[0]);
    loadGDT(&gdtr);
}

////
// Load the table register with our TSS.
// (This can only be done from protected mode)
//
pub fn loadTSS() void {
    asm volatile ("ltr %[desc]"
        :
        : [desc] "r" (TSS_DESC),
    );
}
