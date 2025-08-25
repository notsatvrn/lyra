const std = @import("std");
const Target = std.Target;
const FeatureSet = Target.Cpu.Feature.Set;

pub fn build(b: *std.Build) void {
    const arch = b.standardTargetOptions(.{}).result.cpu.arch;

    const features = switch (arch) {
        .x86_64 => x86_64: {
            const Feature = Target.x86.Feature;

            // Disable all hardware floating point features.
            var features_sub = FeatureSet.empty;
            features_sub.addFeature(@intFromEnum(Feature.x87));
            features_sub.addFeature(@intFromEnum(Feature.mmx));
            features_sub.addFeature(@intFromEnum(Feature.sse));
            features_sub.addFeature(@intFromEnum(Feature.sse2));
            features_sub.addFeature(@intFromEnum(Feature.avx));
            features_sub.addFeature(@intFromEnum(Feature.avx2));
            // Enable software floating point instead.
            var features_add = FeatureSet.empty;
            features_add.addFeature(@intFromEnum(Feature.soft_float));

            break :x86_64 .{ features_add, features_sub };
        },
        .aarch64, .riscv64 => .{ FeatureSet.empty, FeatureSet.empty },
        else => @panic("Unsupported architecture. Only 64-bit x86, RISC-V, and ARM are supported."),
    };

    const target = b.resolveTargetQuery(.{
        .cpu_arch = arch,
        .os_tag = .freestanding,
        .abi = .none,
        .cpu_features_add = features[0],
        .cpu_features_sub = features[1],
    });

    // Options for the kernel executable.
    var exe_options = std.Build.ExecutableOptions{
        .name = "lyra",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = b.standardOptimizeOption(.{}),
        .strip = true,
        .linkage = .static, // Disable dynamic linking.
        .pic = false, // Disable position independent code.
        .omit_frame_pointer = false, // Needed for stack traces.
    };

    if (arch == .x86_64) exe_options.code_model = .kernel; // Higher half kernel.

    // Create the kernel executable.
    const kernel = b.addExecutable(exe_options);

    // Disable features that are problematic in kernel space.
    kernel.root_module.red_zone = false;
    kernel.root_module.stack_check = false;
    kernel.root_module.stack_protector = false;
    kernel.want_lto = false;
    // Delete unused sections to reduce the kernel size.
    kernel.link_function_sections = true;
    kernel.link_data_sections = true;
    kernel.link_gc_sections = true;
    // Force the page size to 4 KiB to prevent binary bloat.
    kernel.link_z_max_page_size = 0x1000;

    switch (arch) {
        .x86_64 => {
            kernel.setLinkerScript(b.path("src/arch/x86_64/linker.ld"));
            kernel.addAssemblyFile(b.path("src/arch/x86_64/int/isr_stubs.s"));
        },
        inline else => |a| {
            kernel.setLinkerScript(b.path("src/arch/" ++ @tagName(a) ++ "/linker.ld"));

            if (b.lazyDependency("dtb", .{})) |dtb| {
                const module = dtb.module("dtb");
                kernel.root_module.addImport("dtb", module);
            }
        },
    }

    b.installArtifact(kernel);
}
