const std = @import("std");
const common = @import("common.zig");

const collections = @import("../util/collections.zig");

const Flags = enum {
    Help,
    Version,
    Working,
    MaxErr,
    None,
    Include,
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
});

const descriptions = std.StaticStringMap([]const u8).initComptime(&.{
    .{ "--help, -h", ": Print this help message." },

    .{ "--version, -v", ": Print version info." },

    .{ "--working, -w", " <path>: Set working directory." },

    .{ "--max-err, -m", " <count>: Set max error count before terminating the compilation. Defaults to 10." },

    .{ "--include, -I", " <path>: Add <path> to the searchpath of the compiler. Can be relative or absolute." },
});

pub fn parseCLI(allocator: std.mem.Allocator) common.CompilerError!common.CompilerSettings {
    const NMap = std.StringHashMapUnmanaged(void);

    var args = std.process.argsWithAllocator(allocator) catch return error.AllocatorFailure;

    _ = args.skip();

    var maybeFile: ?[]const u8 = null;
    var workingDir: []const u8 = undefined;
    var includeDirs = NMap.empty;
    var maxErr: u32 = 10;

    includeDirs.ensureTotalCapacity(allocator, 512) catch return error.AllocatorFailure;

    while (args.next()) |flag| {
        switch (hash(flag)) {
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

            else => if (maybeFile != null) {
                common.log.err("Unexpected commandline option {s}", .{flag});
                return error.UnknownFlag;
            } else {
                maybeFile = flag;
            }
        }
    }

    const collect = struct {
        pub fn collect(count: u32, it: NMap.KeyIterator, _allocator: std.mem.Allocator) ![][]const u8 {
            const ret = _allocator.alloc([]const u8, count) catch return error.AllocatorFailure;
            for (0..count) |i| {
                ret[i] = it.items[i];
            }

            return ret;
        }
    }.collect;

    // TODO: Continue
    std.debug.print("Hello {any}\n", .{includeDirs. });


    return blk: {
        if (maybeFile) |file| break :blk common.CompilerSettings{
            .inputFile = file,
            .workingDir = workingDir,
            .includeDirs = try collections.Collect(
                collections.SliceIteratorType([]const u8, .Forward),
                []const u8,

                collections.SliceIterator(.Forward, try collect(includeDirs.count(), includeDirs.keyIterator(), allocator)),
                allocator
            ),
            .maxErr = maxErr,
        }
        else {
            common.log.err("jaslc expects an input file.", .{});
            return error.NoSourceFile;
        }
    };
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
