const std = @import("std");
const Target = std.Target;
const Feature = Target.x86.Feature;
const FeatureSet = Target.Cpu.Feature.Set;

pub fn build(b: *std.Build) void {
    const arch = b.standardTargetOptions(.{}).result.cpu.arch;
    if (arch != .x86_64) @panic("lyra only supports x86-64");

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

    const target = b.resolveTargetQuery(.{
        .cpu_arch = arch,
        .cpu_model = .baseline,
        .cpu_features_add = features_add,
        .cpu_features_sub = features_sub,
        .os_tag = .freestanding,
        .abi = .none,
        .ofmt = .elf,
    });

    const module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = b.standardOptimizeOption(.{}),
        // Decrease binary size.
        .strip = true,
        // Disable features that are problematic in kernel space.
        .pic = false,
        .red_zone = false,
        .stack_check = false,
        .stack_protector = false,
        // Needed for stack traces.
        .omit_frame_pointer = false,
        // Higher-half kernel code model.
        .code_model = .kernel,
    });

    const kernel = b.addExecutable(.{
        .name = "lyra",
        .root_module = module,
        .linkage = .static,
        .use_lld = true,
        .use_llvm = true,
    });

    // We want to use our own entry (kmain)
    kernel.entry = .disabled;
    // LTO causes boot failure.
    kernel.lto = .none;
    // Delete unused sections to reduce the kernel size.
    kernel.link_function_sections = true;
    kernel.link_data_sections = true;
    kernel.link_gc_sections = true;
    // Force the page size to 4 KiB to prevent binary bloat.
    kernel.link_z_max_page_size = 0x1000;

    kernel.setLinkerScript(b.path("src/linker.ld"));
    kernel.addAssemblyFile(b.path("src/int/isr_stubs.s"));

    const utils = b.dependency("utils", .{ .use_spinlock = true });
    const utils_module = utils.module("utils");
    kernel.root_module.addImport("utils", utils_module);

    {
        kernel.addIncludePath(b.path("uACPI/include"));

        const cflags = [_][]const u8{
            "-DUACPI_BAREBONES_MODE", // missing some functions for full implementation
            "-DUACPI_SIZED_FREES", // need size to know how much memory to actually free
        };

        const src_files = [_][]const u8{
            "tables.c",
            "types.c",
            "uacpi.c",
            "utilities.c",
            "interpreter.c",
            "opcodes.c",
            "namespace.c",
            "stdlib.c",
            "shareable.c",
            "opregion.c",
            "default_handlers.c",
            "io.c",
            "notify.c",
            "sleep.c",
            "registers.c",
            "resources.c",
            "event.c",
            "mutex.c",
            "osi.c",
        };

        inline for (src_files) |src| {
            kernel.addCSourceFile(.{
                .file = b.path("uACPI/source/" ++ src),
                .flags = &cflags,
            });
        }
    }

    b.installArtifact(kernel);
}
