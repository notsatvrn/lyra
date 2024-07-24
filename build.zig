const std = @import("std");
const Target = std.Target;
const Feature = Target.Cpu.Feature;

pub fn build(b: *std.Build) void {
    const provided_arch = b.standardTargetOptions(.{}).result.cpu.arch;

    const arch = switch (provided_arch) {
        .x86, .x86_64 => std.Target.Cpu.Arch.x86,
        else => @panic("Only x86 is supported at this time."),
    };

    const features = switch (arch) {
        .x86 => x86: {
            const features = Target.x86.Feature;

            var features_add = Feature.Set.empty;
            features_add.addFeature(@intFromEnum(features.soft_float));

            var features_sub = Feature.Set.empty;
            features_sub.addFeature(@intFromEnum(features.mmx));
            features_sub.addFeature(@intFromEnum(features.sse));
            features_sub.addFeature(@intFromEnum(features.sse2));
            features_sub.addFeature(@intFromEnum(features.avx));
            features_sub.addFeature(@intFromEnum(features.avx2));

            break :x86 .{ features_add, features_sub };
        },
        else => unreachable,
    };

    const target = b.resolveTargetQuery(.{
        .cpu_arch = arch,
        .os_tag = .freestanding,
        .abi = .none,
        .cpu_features_add = features[0],
        .cpu_features_sub = features[1],
    });

    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "lyra",
        .root_source_file = b.path("src/kmain.zig"),
        .target = target,
        .optimize = optimize,
    });

    switch (arch) {
        .x86 => setupX86(b, exe),
        else => unreachable,
    }

    b.installArtifact(exe);
}

fn setupX86(b: *std.Build, exe: *std.Build.Step.Compile) void {
    //exe.addAssemblyFile(b.path("src/arch/x86/start.s"));
    exe.setLinkerScriptPath(b.path("src/arch/x86/linker.ld"));
}
