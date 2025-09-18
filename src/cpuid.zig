const limine = @import("limine.zig");

// VENDOR

// zig fmt: off
pub const Vendor = enum {
    // the big dogs
    intel, amd,

    // VIA and related vendors
    via, centaur, zhaoxin,

    // hypervisor vendors
    tcg, kvm, xen, hyper_v,
    virtualbox, parallels,
    vmware, qnx, bhyve,

    other,
};
// zig fmt: on

pub var vendor: Vendor = .other;

fn integerify(comptime str: []const u8) u96 {
    if (str.len != 12) @compileError("integerify with string len != 12");
    return @bitCast(@as(*const [12]u8, @ptrCast(str)).*);
}

// FEATURES

pub const Features = struct {
    pml5: bool,
    hypervisor: bool,

    // timing
    invariant_tsc: bool,
    tsc_deadline: bool,
    x2apic: bool,

    // FPU / SSE / AVX
    xsave: bool,
    osxsave: bool,
    sse3: bool,
    ssse3: bool,
    fma: bool,
    sse41: bool,
    sse42: bool,
    avx: bool,
    aes: bool,

    // RNG
    rdrand: bool,
    rdseed: bool,
};

pub var features: Features = undefined;

// PARSE CPUID

pub fn identify() void {
    vendor = blk: {
        var ebx: u32 = 0;
        var ecx: u32 = 0;
        var edx: u32 = 0;
        asm volatile ("cpuid"
            : [_] "={edx}" (edx),
              [_] "={ecx}" (ecx),
              [_] "={ebx}" (ebx),
            : [_] "{eax}" (0),
            : .{ .eax = true });
        const value = @as(u96, ecx) << 64 |
            @as(u96, edx) << 32 |
            @as(u96, ebx);

        // https://wiki.osdev.org/CPUID#CPU_Vendor_ID_String
        // https://en.wikipedia.org/wiki/CPUID#EAX=0:_Highest_Function_Parameter_and_Manufacturer_ID
        break :blk switch (value) {
            integerify("GenuineIntel") => .intel,
            integerify("GenuineIotel") => .intel, // rare
            integerify("AuthenticAMD") => .amd,

            integerify("VIA VIA VIA ") => .via,
            integerify("CentaurHauls") => .centaur,
            integerify("  Shanghai  ") => .zhaoxin,

            integerify("TCGTCGTCGTCG") => .tcg,
            integerify(" KVMKVMKVM  ") => .kvm,
            integerify("XenVMMXenVMM") => .xen,
            integerify("Microsoft Hv") => .hyper_v,
            integerify("VBoxVBoxVBox") => .virtualbox,
            integerify(" prl hyperv ") => .parallels,
            // rare endianness mismatch bug in parallels
            integerify(" lrpepyh vr ") => .parallels,
            integerify("VMwareVMware") => .vmware,
            integerify(" QNXQVMBSQG ") => .qnx,
            integerify("bhyve bhvye ") => .bhyve,

            else => .other,
        };
    };

    // features we can check with Limine
    features.pml5 = limine.paging_mode.response.mode == 1;
    features.x2apic = limine.cpus.response.flags & 1 == 1;

    // features on CPUID leaf 1
    {
        var edx: u32 = undefined;
        var ecx: u32 = undefined;
        asm volatile ("cpuid"
            : [_] "={ecx}" (ecx),
              [_] "={edx}" (edx),
            : [_] "{eax}" (1),
            : .{ .eax = true, .ebx = true });
        // zig fmt: off
        features.sse3 =         ecx & 1 == 1;
        features.ssse3 =        (ecx >> 9) & 1 == 1;
        features.fma =          (ecx >> 12) & 1 == 1;
        features.sse41 =        (ecx >> 19) & 1 == 1;
        features.sse42 =        (ecx >> 20) & 1 == 1;
        // x2apic (bit 21) skipped, check with Limine
        features.tsc_deadline = (ecx >> 24) & 1 == 1;
        features.aes =          (ecx >> 25) & 1 == 1;
        features.xsave =        (ecx >> 26) & 1 == 1;
        features.osxsave =      (ecx >> 27) & 1 == 1;
        features.avx =          (ecx >> 28) & 1 == 1;
        features.rdrand =       (ecx >> 30) & 1 == 1;
        features.hypervisor =   (ecx >> 31) == 1;
        // zig fmt: on
    }

    // features on CPUID leaf 7
    {
        var edx: u32 = undefined;
        var ecx: u32 = undefined;
        var ebx: u32 = undefined;
        asm volatile ("cpuid"
            : [_] "={ebx}" (ebx),
              [_] "={ecx}" (ecx),
              [_] "={edx}" (edx),
            : [_] "{eax}" (7),
            : .{ .eax = true });
        // zig fmt: off
        features.rdseed = (ebx >> 18) & 1 == 1;
        // zig fmt: on
    }

    // features on CPUID leaf 8000'0007h
    {
        var edx: u32 = undefined;
        asm volatile ("cpuid"
            : [_] "={edx}" (edx),
            : [_] "{eax}" (0x8000_0007),
            : .{ .eax = true, .ebx = true, .ecx = true });
        features.invariant_tsc = (edx >> 8) & 1 == 1;
    }

    sse: {
        // enable SSE; also required for FPU / AVX
        // https://osdev.wiki/wiki/SSE#Adding_support
        asm volatile (
            \\mov %cr0, %rax
            \\and $0xFFFB, %ax
            \\or $0x2, %ax
            \\mov %rax, %cr0
            \\mov %cr4, %rax
            \\or $(3 << 9), %ax
            \\mov %rax, %cr4
            ::: .{ .rax = true });

        if (!features.xsave) break :sse;
        // enable XSAVE; required for AVX
        // https://osdev.wiki/wiki/FPU#FPU_control
        asm volatile (
            \\mov %cr4, %rax
            \\or $(1 << 18), %eax
            \\mov %rax, %cr4
            ::: .{ .rax = true });

        if (!features.avx) break :sse;
        // enable AVX; requires XSAVE
        // https://osdev.wiki/wiki/SSE#AVX_2
        asm volatile (
            \\xor %rcx, %rcx
            \\xgetbv
            \\or $7, %eax
            \\xsetbv
            ::: .{ .rax = true, .rcx = true, .rdx = true });
    }
}
