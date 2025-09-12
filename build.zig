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
        .cpu_model = .baseline,
        .cpu_features_add = features[0],
        .cpu_features_sub = features[1],
        .os_tag = .freestanding,
        .abi = .none,
        .ofmt = .elf,
    });

    // Create the kernel executable.
    const kernel = b.addExecutable(.{
        .name = "lyra",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = b.standardOptimizeOption(.{}),
            .strip = true,
        }),
        .linkage = .static,
        .use_lld = true,
        .use_llvm = true,
    });

    // Disable features that are problematic in kernel space.
    kernel.root_module.pic = false;
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
    // Frame pointer is needed for stack traces.
    kernel.root_module.omit_frame_pointer = false;
    // Code model for a higher half kernel.
    if (arch == .x86_64) kernel.root_module.code_model = .kernel;

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
