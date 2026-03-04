const std = @import("std");
const common = @import("core/common.zig");
const util = @import("core/util.zig");
const lexer = @import("lexer/lexer.zig");

pub fn main() void {
    const allocator_t = std.heap.DebugAllocator(.{});
    var alc = allocator_t.init;
    const allocator = alc.allocator();

    var compilerSettings = parseCLI(allocator) catch |err| {
        util.println(allocator, "Compiler exited with code {d} <{s}>", .{@intFromError(err), @errorName(err)});
        return;
    };
    defer compilerSettings.deinit(allocator);

    compilerSettings.print(allocator);
}

fn parseCLI(allocator: std.mem.Allocator) common.CompilerError!common.CompilerSettings {
    var args = std.process.args();
    _ = args.skip();

    var maybeFile: ?[]const u8 = null;
    var workingDir: []const u8 = undefined;

    while (true) {
        const arg = args.next();

        switch (hash(arg)) {
            hash("--help") => printHelp(allocator),
            hash("--version") => printHeader(allocator),
            hash("--working") => {
                const dir = if (args.next()) |next| next else "*";

                if (std.mem.eql(u8, dir, "*")) return error.MissingFlag;

                std.process.changeCurDir(dir) catch |err| {
                    util.println(allocator, "Failed to set working directory to '{s}',\n\tProvided information: {s}", .{dir, @errorName(err)});
                    return error.IOError;
                };

                workingDir = dir;
            },
            hash(null) => {
                break;
            },

            else => if (maybeFile != null) {
                util.println(allocator, "Unexpected commandline option {s}", .{arg.?});
                return error.UnknownFlag;
            } else {
                maybeFile = arg;
            }
        }
    }

    if (maybeFile) |file| {
        return common.CompilerSettings.init(allocator, file, workingDir);
    } else {
        util.println(allocator, "jaslc expects an input file.", .{});
        return error.NoSourceFile;
    }
}

fn printHeader(allocator: std.mem.Allocator) void {
    util.println(
        allocator,
        "The JASL Compiler:" ++
        "\n\tVersion: " ++ common.JASL_VERSION,
        .{}
    );
}

fn printHelp(allocator: std.mem.Allocator) void {
    printHeader(allocator);
    util.println(
        allocator,
        "\n\tUsage:\n\tjaslc <input_file> [flags]\n\n\tFlags:" ++
        "\n\t\t --help: Print this help message.",
        .{}
    );
}

fn hash(str: ?[]const u8) usize {
    if (str == null) {
        return 1;
    } else if (std.mem.eql(u8, str.?, "--help")) {
        return 2;
    } else if (std.mem.eql(u8, str.?, "--version")) {
        return 3;
    } else if (std.mem.eql(u8, str.?, "--working")) {
        return 4;
    }
    else return 0;
}
