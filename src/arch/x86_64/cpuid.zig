const std = @import("std");

// FEATURES

pub const Features = struct {
    cpuid: bool,

    pml5: bool,
    tsc: bool,
    invariant_tsc: bool,
    hypervisor: bool,

    // SSE & FPU
    osxsave: bool,

    // AVX(2)
    avx: bool,
    avx2: bool,
    avx_ifma: bool,
    avx_vnni: bool,

    // AVX-512
    avx512f: bool,
    avx512cd: bool,
    avx512vl: bool,
    avx512dq: bool,
    avx512bw: bool,
    avx512ifma: bool,
    avx512vnni: bool,
    avx512vbmi: bool,
    avx512vbmi2: bool,
    avx512bitalg: bool,
    avx512vpopcntdq: bool,
    avx512bf16: bool,
    avx512fp16: bool,
    avx512gfni: bool,
    avx512vaes: bool,
    avx512vpclmulqdq: bool,
};

pub var features: Features = undefined;

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

inline fn integerify(comptime str: []const u8) u96 {
    if (str.len != 12) @compileError("integerify with string len != 12");
    return @bitCast(@as(*const [12]u8, @ptrCast(str)).*);
}

// https://wiki.osdev.org/CPUID#CPU_Vendor_ID_String
// https://en.wikipedia.org/wiki/CPUID#EAX=0:_Highest_Function_Parameter_and_Manufacturer_ID
inline fn parseVendor(int: u96) Vendor {
    return switch (int) {
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
}

var model_ints: [12]u32 = @splat(0);
pub var model: []const u8 = "";

// PARSE CPUID

pub fn identify() void {
    // the basics

    // TODO: use our own CPUID parser
    const cpuid = @import("cpuid").Features.get();

    // miscellaneous
    features.hypervisor = cpuid.basic.ecx.hypervisor;
    features.pml5 = cpuid.extended_0.ecx.la57;
    features.tsc = cpuid.basic.edx.tsc;
    // SSE & FPU features
    features.osxsave = cpuid.basic.ecx.osxsave;
    // AVX(2) features
    features.avx = cpuid.basic.ecx.avx;
    features.avx2 = cpuid.extended_0.ebx.avx2;
    // AVX-512 features
    features.avx512f = cpuid.extended_0.ebx.avx512_f;
    features.avx512cd = cpuid.extended_0.ebx.avx512_cd;
    features.avx512vl = cpuid.extended_0.ebx.avx512_vl;
    features.avx512dq = cpuid.extended_0.ebx.avx512_dq;
    features.avx512bw = cpuid.extended_0.ebx.avx512_bw;
    features.avx512ifma = cpuid.extended_0.ebx.avx512_ifma;
    features.avx512vnni = cpuid.extended_0.ecx.avx512_vnni;
    features.avx512vbmi = cpuid.extended_0.ecx.avx512_vbmi;
    features.avx512vbmi2 = cpuid.extended_0.ecx.avx512_vbmi2;
    features.avx512bitalg = cpuid.extended_0.ecx.avx512_bitalg;
    features.avx512vpopcntdq = cpuid.extended_0.ecx.avx512_vpopcntdq;
    features.avx512bf16 = cpuid.extended_1.eax.avx512_bf16;
    features.avx512fp16 = cpuid.extended_0.edx.avx512_fp16;
    features.avx512gfni = cpuid.extended_0.ecx.gfni;
    features.avx512vaes = cpuid.extended_0.ecx.vaes;
    features.avx512vpclmulqdq = cpuid.extended_0.ecx.vpclmulqdq;

    const max_extended = blk: {
        var eax: u32 = 0x80000000;
        var ebx: u32 = 0;
        var ecx: u32 = 0;
        var edx: u32 = 0;
        asm volatile ("cpuid"
            : [_] "={edx}" (edx),
              [_] "={ecx}" (ecx),
              [_] "={ebx}" (ebx),
              [_] "={eax}" (eax),
        );
        break :blk eax;
    };

    _ = max_extended; // qemu cpuid implementation just doesnt work with this for whatever reason

    if (features.tsc) {
        // https://github.com/dterei/tsc/
        features.invariant_tsc = asm (
            \\.intel_syntax noprefix
            \\
            \\mov eax, 0x80000007
            \\cpuid
            \\mov eax, 1
            \\test edx, 1 << 8
            \\jnz endNonStopTSC
            \\
            \\xor eax, eax
            \\endNonStopTSC:
            \\
            \\.att_syntax prefix
            : [_] "={eax}" (-> bool),
            :
            : "eax", "ebx", "ecx", "edx"
        );
    }

    // enable SSE / AVX

    // https://osdev.wiki/wiki/SSE#Adding_support
    asm volatile (
        \\.intel_syntax noprefix
        \\
        \\mov rax, cr0
        \\and ax, 0xFFFB
        \\or ax, 0x2
        \\mov cr0, rax
        \\mov rax, cr4
        \\or ax, 3 << 9
        \\mov cr4, rax
        \\
        \\.att_syntax prefix
        ::: "rax");

    if (features.osxsave) {
        // https://osdev.wiki/wiki/FPU#FPU_control
        asm volatile (
            \\.intel_syntax noprefix
            \\
            \\mov rax, cr4
            \\or ax, 1 << 18
            \\mov cr4, rax
            \\
            \\.att_syntax prefix
            ::: "rax");
    }

    // FIXME: #UD on some systems
    if (false and features.avx) {
        // https://osdev.wiki/wiki/SSE#AVX_2
        asm volatile (
            \\.intel_syntax noprefix
            \\
            \\xor rcx, rcx
            \\xgetbv
            \\or eax, 7
            \\xsetbv
            \\
            \\.att_syntax prefix
            ::: "rax", "rcx", "rdx");
    }

    // read CPU vendor

    var ebx: u32 = 0;
    var ecx: u32 = 0;
    var edx: u32 = 0;
    asm volatile ("cpuid"
        : [_] "={edx}" (edx),
          [_] "={ecx}" (ecx),
          [_] "={ebx}" (ebx),
        : [_] "{eax}" (0),
        : "={eax}"
    );

    const value = @as(u96, ecx) << 64 |
        @as(u96, edx) << 32 |
        @as(u96, ebx);

    vendor = parseVendor(value);

    // read CPU model string

    var eax1: u32 = 0x80000002;
    var ebx1: u32 = 0;
    var ecx1: u32 = 0;
    var edx1: u32 = 0;
    asm volatile ("cpuid"
        : [_] "={edx}" (edx1),
          [_] "={ecx}" (ecx1),
          [_] "={ebx}" (ebx1),
          [_] "={eax}" (eax1),
    );

    var eax2: u32 = 0x80000003;
    var ebx2: u32 = 0;
    var ecx2: u32 = 0;
    var edx2: u32 = 0;
    asm volatile ("cpuid"
        : [_] "={edx}" (edx2),
          [_] "={ecx}" (ecx2),
          [_] "={ebx}" (ebx2),
          [_] "={eax}" (eax2),
    );

    var eax3: u32 = 0x80000004;
    var ebx3: u32 = 0;
    var ecx3: u32 = 0;
    var edx3: u32 = 0;
    asm volatile ("cpuid"
        : [_] "={edx}" (edx3),
          [_] "={ecx}" (ecx3),
          [_] "={ebx}" (ebx3),
          [_] "={eax}" (eax3),
    );

    model_ints = .{ eax1, ebx1, ecx1, edx1, eax2, ebx2, ecx2, edx2, eax3, ebx3, ecx3, edx3 };
    model = @ptrCast(model_ints[0..12]);
    if (false) {
        for (0..model.len) |i| {
            if (model[i] == 0) {
                model = model[0..i];
                break;
            }
        }
    }
}
