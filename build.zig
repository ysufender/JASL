const std = @import("std");

const targets = [_]std.Target.Query{
    .{},
    .{ .os_tag = .windows, .cpu_arch = .x86_64 },
    .{ .os_tag = .linux,   .cpu_arch = .x86_64 },
};

const version = std.SemanticVersion{
    .major = 0,
    .minor = 0,
    .patch = 1,
};

pub fn build(b: *std.Build) void {
    addTargets(b, .Debug);
    addTargets(b, .ReleaseFast);
    addTargets(b, .ReleaseSafe);
    addTargets(b, .ReleaseSmall);
}

fn addTargets(b: *std.Build, optimize: std.builtin.OptimizeMode) void {
    var seen = std.StringHashMap(void).init(b.allocator);
    defer seen.deinit();

    const toLower = std.ascii.allocLowerString;
    const print = std.fmt.allocPrint;

    for (targets) |query| {
        const target   = b.resolveTargetQuery(query);

        const targetName = print(b.allocator, "jaslc-{s}-{s}-{s}", .{
            toLower(b.allocator, @tagName(optimize)) catch unreachable,
            @tagName(target.result.os.tag),
            @tagName(target.result.cpu.arch),
        }) catch unreachable;

        if (seen.contains(targetName)) continue;
        seen.putNoClobber(targetName, {}) catch unreachable;

        const opts = b.addOptions();
        opts.addOption(bool, "isDebug", optimize == .Debug);
        opts.addOption([]const u8, "version", print(b.allocator, "v{d}.{d}.{d}", .{
            version.major,
            version.minor,
            version.patch,
        }) catch unreachable);

        const exe = b.addExecutable(.{
            .name = targetName,
            .version = version,
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc  = target.result.os.tag == .windows,
                .error_tracing = optimize == .Debug,
                .strip = optimize != .Debug,
            }),
        });
        exe.root_module.addOptions("config", opts);
        const install = b.addInstallArtifact(exe, .{});

        const step = b.step(targetName, print(
            b.allocator,
            "Build for {s}",
            .{targetName},
        ) catch unreachable);
        step.dependOn(&install.step);
        step.dependOn(b.getInstallStep());
    }
}
