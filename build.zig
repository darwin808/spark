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

    // Benchmarks
    const benchmarks = [_][]const u8{
        "plaintext",
        "json",
        "db",
        "queries",
    };

    var bench_steps: [benchmarks.len]?*std.Build.Step = [_]?*std.Build.Step{null} ** benchmarks.len;

    for (benchmarks, 0..) |benchmark, idx| {
        const bench_mod = b.createModule(.{
            .root_source_file = b.path(b.fmt("benchmarks/{s}.zig", .{benchmark})),
            .target = target,
            .optimize = optimize,
        });
        bench_mod.addImport("spark", spark_mod);

        const bench_exe = b.addExecutable(.{
            .name = b.fmt("bench-{s}", .{benchmark}),
            .root_module = bench_mod,
        });

        const install = b.addInstallArtifact(bench_exe, .{});
        const run = b.addRunArtifact(bench_exe);
        run.step.dependOn(&install.step);

        const run_step = b.step(b.fmt("run-bench-{s}", .{benchmark}), b.fmt("Run the {s} benchmark", .{benchmark}));
        run_step.dependOn(&run.step);

        bench_steps[idx] = &run.step;
    }

    const bench_step = b.step("bench", "Build all benchmarks");
    for (bench_steps) |opt_step| {
        if (opt_step) |step| {
            bench_step.dependOn(step);
        }
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
