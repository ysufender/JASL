const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

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
            .optimize = optimize,
        }),
        .linkage = .static
    });
    exe.linkLibC();
    b.exe_dir = "build/";
    b.installArtifact(exe);
}
