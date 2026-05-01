const std = @import("std");
const common = @import("common.zig");
const hashmap = @import("../util/hashmap.zig");

const collections = @import("../util/collections.zig");

const Flags = enum {
    Help,
    Version,
    Working,
    MaxErr,
    None,
    Include,
    Flag,
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

    .{ "--include", .Include },
    .{ "-I", .Include },

    .{ "--print-ast", .Flag },

    .{ "--parse-only", .Flag },

    .{ "--typecheck-only", .Flag },

    .{ "--resolve-only", .Flag },
});

const descriptions = std.StaticStringMap([]const u8).initComptime(&.{
    .{ "--help, -h", ": Print this help message." },

    .{ "--version, -v", ": Print version info." },

    .{ "--working, -w", " <path>: Set working directory." },

    .{ "--max-err, -m", " <count>: Set max error count before terminating the compilation. Defaults to 10." },

    .{ "--include, -I", " <path>: Add <path> to the searchpath of the compiler. Can be relative or absolute." },

    .{ "--print-ast", ": Print a pretty(!) formatted AST dump to stdout." },

    .{ "--parse-only", ": Parse the project, do not compile." },
    .{ "--typecheck-only", ": Typecheck the project, do not compile." },
    .{ "--resolve-only", ": Resolve the project, do not compile." },
});

pub fn parseCLI(allocator: std.mem.Allocator) common.CompilerError!common.CompilerSettings {
    const NMap = std.StringHashMapUnmanaged(void);

    var args = std.process.argsWithAllocator(allocator) catch return error.AllocatorFailure;

    _ = args.skip();

    var maybeFile: ?[]const u8 = null;
    var workingDir: []const u8 = undefined;
    var includeDirs = NMap.empty;
    var maxErr: u32 = 10;
    var settings = common.CompilerSettings{
        .flags = .empty,
        .workingDir = "",
        .includeDirs = &.{},
        .inputFile = "",
        .maxErr = 0,
    };

    settings.flags.ensureTotalCapacity(allocator, 128) catch return error.AllocatorFailure;

    includeDirs.ensureTotalCapacity(allocator, 512) catch return error.AllocatorFailure;

    while (args.next()) |flag| {
        switch (hash(flag)) {
            .Help => return printHelp(),
            .Version => return printHeader(),
            .Working => {
                const dir = if (args.next()) |next| next else return error.MissingFlag;

                std.process.changeCurDir(dir) catch |err| {
                    common.log.err("Failed to set working directory to '{s}',\n\tProvided information: {s}", .{dir, @errorName(err)});
                    return error.IOError;
                };

                workingDir = std.process.getCwdAlloc(allocator) catch return error.AllocatorFailure;
            },
            .MaxErr => {
                const max = if (args.next()) |next| next else {
                    common.log.err("Expected an integer value, received nothing.", .{});
                    return error.MissingFlag;
                };

                maxErr = std.fmt.parseInt(u32, max, 10) catch {
                    common.log.err("Expected an integer value, received '{s}'", .{max});

                    return error.UnknownFlag;
                };
            },
            .Include => {
                if (args.next()) |arg| {
                    const path = std.fs.realpathAlloc(allocator, arg) catch |err| switch (err) {
                        error.OutOfMemory => return error.AllocatorFailure,
                        else => {
                            common.log.info("Given path '{s}' couldn't be resolved.", .{arg});
                            return error.IOError;
                        }
                    };

                    _ = includeDirs.getOrPutValue(allocator, path, {}) catch return error.AllocatorFailure;
                }
                else {
                    common.log.err("Expected a path after include flag.", .{});
                }
            },

            else =>
                if (
                    std.mem.startsWith(u8, flag, "--")
                    or std.mem.startsWith(u8, flag, "-")
                ) {
                    try settings.setFlag(flag);
                }
                else if (maybeFile != null) {
                    common.log.err("Unexpected commandline option {s}", .{flag});
                    return error.UnknownFlag;
                }
                else {
                    maybeFile = flag;
                }
        }
    }

    const collect = struct {
        pub fn collect(count: u32, _it: NMap.KeyIterator, _allocator: std.mem.Allocator) ![][]const u8 {
            var it = _it;
            const ret = _allocator.alloc([]const u8, count) catch return error.AllocatorFailure;
            var i: u32 = 0;
            while (it.next()) |n| : (i += 1) {
                ret[i] = n.*;
            }
            return ret;
        }
    }.collect;

    return blk: {
        if (maybeFile) |file| break :blk common.CompilerSettings{
            .inputFile = file,
            .workingDir = workingDir,
            .includeDirs = try collect(
                includeDirs.count(),
                includeDirs.keyIterator(),
                allocator
            ),
            .maxErr = maxErr,
            .flags = settings.flags,
        }
        else {
            common.log.err("jaslc expects an input file.", .{});
            return error.NoSourceFile;
        }
    };
}

fn printHeader() common.CompilerError {
    common.log.info(
        "The JASL Compiler:" ++
        "\n\tVersion: " ++ common.JASL_VERSION,
        .{}
    );

    return error.Terminate; 
}

fn printHelp() common.CompilerError {
    printHeader() catch { };
    common.log.info("\n\tUsage:\n\tjaslc <input_file> [flags]\n\n\tFlags:", .{});

    for (descriptions.keys()) |flag| {
        common.log.info("\t\t{s}{s}", .{flag, descriptions.get(flag).?});
    }

    return error.Terminate; 
}  

fn hash(str: []const u8) Flags {
    if (flags.get(str)) |flag| {
        return flag;
    }

    return .None;
}
