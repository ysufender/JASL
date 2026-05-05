const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    b.install_prefix = "build";

    const target = b.standardTargetOptions(.{});

    const testing = b.addTest(.{
        .name = "jaslc-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = .Debug,
            .error_tracing = true,
        }),
    });
    b.installArtifact(testing);

    const runTest = b.step("test", "Execute unit tests");
    runTest.dependOn(&testing.step);

    const exe = b.addExecutable(.{
        .name = "jaslc",
        .version = .{
            .major = 0,
            .minor = 0,
            .patch = 1,
        },
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = .Debug,
            .error_tracing = true,
        }),
        .linkage = .static,
    });
    exe.root_module.error_tracing = true;
    exe.step.dependOn(runTest);
    b.installArtifact(exe);
}
