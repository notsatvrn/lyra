// https://wiki.osdev.org/Global_Descriptor_Table
//
// Original code from Andrea Orru's Zen kernel project (reboot branch)
// https://github.com/AndreaOrru/zen/blob/reboot/kernel/src/cpu/gdt.zig

const std = @import("std");
const assert = std.debug.assert;
const memory = @import("memory.zig");

// STANDARD SEGMENT STRUCTURES

pub const Access = packed struct(u8) {
    accessed: bool = false,
    mutable: bool = true,
    // direction / conforming
    dir_con: bool = false,
    type: Type,
    // set to false for TSS
    regular: bool = true,
    level: PrivilegeLevel,
    present: bool = true,

    pub const PrivilegeLevel = enum(u2) {
        kernel = 0b00,
        user = 0b11,
    };

    pub const Type = enum(u1) {
        data = 0,
        code = 1,
    };
};

pub const Flags = packed struct(u4) {
    reserved: u1 = 0,
    size: Size = .x64,
    page_granularity: bool = true,

    pub const Size = enum(u2) {
        x64 = 0b01,
        x32 = 0b10,
        x16 = 0b00,
    };
};

pub const SegmentSelector = enum(u16) {
    null_desc = 0x00,
    kernel_code = 0x08,
    kernel_data = 0x10,
    user_code = 0x18,
    user_data = 0x20,
    tss = 0x28,
};

// Limit and base are ignored on x86-64.
const SegmentDescriptor = packed struct(u64) {
    limit_lo: u16 = 0xFFFF,
    base_lo: u24 = 0,
    access: Access,
    limit_hi: u4 = 0xF,
    flags: Flags = .{},
    base_hi: u8 = 0,
};

// TASK STATE SEGMENT STRUCTURES

const Tss = packed struct {
    reserved1: u32,
    rsp0: u64, // Stack pointer to load when switching to Ring 0.
    rsp1: u64,
    rsp2: u64,
    reserved2: u64,
    ist1: u64,
    ist2: u64,
    ist3: u64,
    ist4: u64,
    ist5: u64,
    ist6: u64,
    ist7: u64,
    reserved3: u64,
    reserved4: u16,
    iomap_base: u16,
};

// 64-bit segment descriptor extension.
// Goes after a normal segment descriptor.
const DescriptorExtension = packed struct(u64) {
    base: u32,
    reserved: u32,
};

// TABLE DATA

pub const Register = packed struct {
    limit: u16,
    base: u64,
};

var init_tss: Tss = undefined;
var init_gdt = [_]SegmentDescriptor{
    undefined, // null descriptor
    .{ .access = .{ .level = .kernel, .type = .code } },
    .{ .access = .{ .level = .kernel, .type = .data } },
    .{ .access = .{ .level = .user, .type = .code } },
    .{ .access = .{ .level = .user, .type = .data } },
    // Task State Segment Descriptor (fill in at runtime).
    // Fills two segments to use a 64-bit pointer on x86-64.
    undefined, // first half
    undefined, // second half
};
var gdt: []SegmentDescriptor = &init_gdt;

// UTILITIES

/// Load the initial Global Descriptor Table.
pub inline fn init() void {
    writeTSS(&init_tss, 0);
    load(0);
}

/// Create a new GDT with a TSS for each CPU.
pub fn update(cpus: usize) !void {
    // Allocate a new GDT with enough space to store a TSS for each CPU.
    gdt = try memory.allocator.alloc(SegmentDescriptor, 5 + (cpus * 2));
    // Allocate a Task State Segment for each new CPU.
    var tss = try memory.allocator.alloc(Tss, cpus);
    // Copy the main segments from the initial GDT.
    @memcpy(gdt[0..5], init_gdt[0..5]);
    // Write TSS entries for each CPU.
    for (0..cpus) |i| writeTSS(&tss[i], i);
}

/// Write the initial state for a Task State Segment.
pub fn writeTSS(tss: *Tss, offset: usize) void {
    const selector = @intFromEnum(SegmentSelector.tss) / @sizeOf(SegmentDescriptor);
    var segment: *SegmentDescriptor = &gdt[selector + (offset * 2)];
    var extension: *DescriptorExtension = @ptrCast(&gdt[selector + (offset * 2) + 1]);

    const base = @intFromPtr(tss);
    const limit = @sizeOf(Tss) - 1;

    segment.base_lo = @truncate(base);
    segment.base_hi = @truncate(base >> 24);
    segment.limit_lo = limit & 0xFFFF;
    segment.limit_hi = limit >> 16;

    segment.access = .{
        .accessed = true,
        .mutable = false,
        .type = .code,
        .regular = false,
        .level = .kernel,
    };
    segment.flags = .{};

    extension.base = @truncate(base >> 32);
    extension.reserved = 0;
}

/// Load the current Global Descriptor Table.
/// Sets the task register to the TSS offset.
pub inline fn load(tss: usize) void {
    // Set the GDT register.
    const gdtr = Register{
        .limit = @truncate((@sizeOf(SegmentDescriptor) * gdt.len) - 1),
        .base = @intFromPtr(gdt.ptr),
    };
    asm volatile ("lgdt (%[gdtr])"
        :
        : [gdtr] "r" (&gdtr),
    );

    // Set data segment registers and reload the code segment.
    // Data segment registers are set to null as they are unused in 64-bit mode.
    asm volatile (
        \\ push %[kernel_code]
        \\ lea 1f(%rip), %rax
        \\ push %rax
        \\ lretq
        \\
        \\ 1:
        \\     mov %[null_desc], %ax
        \\     mov %ax, %ds
        \\     mov %ax, %es
        \\     mov %ax, %fs
        \\     mov %ax, %gs
        \\     mov %ax, %ss
        :
        : [kernel_code] "i" (SegmentSelector.kernel_code),
          [null_desc] "i" (SegmentSelector.null_desc),
        : .{ .rax = true, .memory = true });

    // Set the Task Register.
    const start = @intFromEnum(SegmentSelector.tss);
    const val = start + (tss * @sizeOf(SegmentDescriptor) * 2);
    asm volatile ("ltr %[selector]"
        :
        // truncate because ltr takes r/m16
        : [selector] "r" (@as(u16, @truncate(val))),
    );
}

/// Get the current CPU's Task Register as an offset into the GDT.
pub inline fn str() usize {
    return (asm volatile ("str %[tr]"
        : [tr] "=r" (-> usize),
    ) - @intFromEnum(SegmentSelector.tss)) / (@sizeOf(SegmentDescriptor) * 2);
}
