const std = @import("std");
const common = @import("common.zig");

const Flags = enum {
    Help,
    Version,
    Working,
    MaxErr,
    None,
};

const flags = std.StaticStringMap(Flags).initComptime(&.{
    .{ "--help", .Help },
    .{ "-h", .Help },

    .{ "--version", .Version },
    .{ "-v", .Version },

    .{ "--working", .Working },
    .{ "-w", .Working },

    .{ "--max-err", .MaxErr },
    .{ "-m", .MaxErr },
});

const descriptions = std.StaticStringMap([]const u8).initComptime(&.{
    .{ "--help, -h", ": Print this help message." },

    .{ "--version, -v", ": Print version info." },

    .{ "--working, -w", " <path>: Set working directory." },

    .{ "--max-err, -m", " <count>: Set max error count before terminating the compilation. Defaults to 10." },
});

pub fn parseCLI(allocator: std.mem.Allocator) common.CompilerError!common.CompilerSettings {
    var args = std.process.argsWithAllocator(allocator) catch return error.AllocatorFailure;

    _ = args.skip();

    var maybeFile: ?[]const u8 = null;
    var workingDir: []const u8 = undefined;
    var maxErr: u32 = 10;

    while (args.next()) |arg| {
        switch (hash(arg)) {
            .Help => printHelp(),
            .Version => printHeader(),
            .Working => {
                const dir = if (args.next()) |next| next else return error.MissingFlag;

                std.process.changeCurDir(dir) catch |err| {
                    common.log.err("Failed to set working directory to '{s}',\n\tProvided information: {s}", .{dir, @errorName(err)});
                    return error.IOError;
                };

                workingDir = std.process.getCwdAlloc(allocator) catch return error.AllocatorFailure;
            },
            .MaxErr => {
                const max = if (args.next()) |next| next else return error.MissingFlag;

                maxErr = std.fmt.parseInt(u32, max, 10) catch return error.UnknownFlag;
            },

            else => if (maybeFile != null) {
                common.log.err("Unexpected commandline option {s}", .{arg});
                return error.UnknownFlag;
            } else {
                maybeFile = arg;
            }
        }
    }

    if (maybeFile) |file| {
        return .{
            .inputFile = file,
            .workingDir = workingDir,
            .maxErr = maxErr,
        };
    } else {
        common.log.err("jaslc expects an input file.", .{});
        return error.NoSourceFile;
    }
}

fn printHeader() void {
    common.log.info(
        "The JASL Compiler:" ++
        "\n\tVersion: " ++ common.JASL_VERSION,
        .{}
    );
}

fn printHelp() void {
    printHeader();
    common.log.info("\n\tUsage:\n\tjaslc <input_file> [flags]\n\n\tFlags:", .{});

    for (descriptions.keys()) |flag| {
        common.log.info("\t\t{s}{s}", .{flag, descriptions.get(flag).?});
    }
}  

fn hash(str: []const u8) Flags {
    if (flags.get(str)) |flag| {
        return flag;
    }

    return .None;
}
