const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Main library module
    const spark_mod = b.addModule("spark", .{
        .root_source_file = b.path("src/spark.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Examples
    const examples = [_][]const u8{
        "hello_world",
        "rest_api",
    };

    for (examples) |example| {
        const exe_mod = b.createModule(.{
            .root_source_file = b.path(b.fmt("examples/{s}.zig", .{example})),
            .target = target,
            .optimize = optimize,
        });
        exe_mod.addImport("spark", spark_mod);

        const exe = b.addExecutable(.{
            .name = example,
            .root_module = exe_mod,
        });

        const install = b.addInstallArtifact(exe, .{});
        const run = b.addRunArtifact(exe);
        run.step.dependOn(&install.step);

        const run_step = b.step(b.fmt("run-{s}", .{example}), b.fmt("Run the {s} example", .{example}));
        run_step.dependOn(&run.step);
    }

    // Tests
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/spark.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib_tests = b.addTest(.{
        .root_module = test_mod,
    });

    const run_lib_tests = b.addRunArtifact(lib_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_tests.step);
}
