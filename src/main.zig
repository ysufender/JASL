const std = @import("std");
const common = @import("core/common.zig");
const lexer = @import("lexer/lexer.zig");

pub fn main() !void {
    // Init Allocator
    const allocator_t = std.heap.DebugAllocator(.{ });
    var alc = allocator_t.init;
    const allocator = alc.allocator();

    // Init IO
    var io = std.Io.Threaded.init(allocator);
    defer io.deinit();
        
    innerMain(allocator, io.io()) catch |err| {
        std.log.err("Compiler exited with code {d} <{s}>", .{@intFromError(err), @errorName(err)});
        if (err == error.InternalError)
            std.log.err("\tThis internal error is likely an allocator fail.", .{});
        return;
    };
    std.log.info("Compiler exited succesfully.", .{});
}

fn innerMain(allocator: std.mem.Allocator, io: std.Io) common.CompilerError!void {
    // Parse CLI
    var compilerSettings = try parseCLI(allocator);
    defer compilerSettings.deinit(allocator);

    // Print Compilation Info
    compilerSettings.print();

    // Open Source File
    const path = std.fs.realpathAlloc(allocator, compilerSettings.inputFile) catch return error.InternalError;
    defer allocator.free(path);

    var sourceFile = std.fs.openFileAbsolute(path, .{.mode = .read_only}) catch {
        std.log.err("Couldn't open source file '{s}'.", .{compilerSettings.inputFile});
        return error.IOError;
    };
    defer sourceFile.close();

    var fileReader = sourceFile.reader(io, &.{});
    const sourceSize = fileReader.getSize() catch return error.InternalError;
    const source = fileReader.interface.readAlloc(allocator, sourceSize) catch return error.InternalError;

    var scanner = try lexer.Scanner.init(allocator, path, source);
    defer scanner.deinit(allocator);

    _ = try scanner.scanAll(allocator);
}

fn parseCLI(allocator: std.mem.Allocator) common.CompilerError!common.CompilerSettings {
    var args = std.process.args();
    _ = args.skip();

    var maybeFile: ?[]const u8 = null;
    var workingDir: []const u8 = undefined;

    while (true) {
        const arg = args.next();

        switch (hash(arg)) {
            hash("--help") => printHelp(),
            hash("--version") => printHeader(),
            hash("--working") => {
                const dir = if (args.next()) |next| next else "*";

                if (std.mem.eql(u8, dir, "*")) return error.MissingFlag;

                std.process.changeCurDir(dir) catch |err| {
                    std.log.err("Failed to set working directory to '{s}',\n\tProvided information: {s}", .{dir, @errorName(err)});
                    return error.IOError;
                };

                workingDir = dir;
            },
            hash(null) => {
                break;
            },

            else => if (maybeFile != null) {
                std.log.err("Unexpected commandline option {s}", .{arg.?});
                return error.UnknownFlag;
            } else {
                maybeFile = arg;
            }
        }
    }

    if (maybeFile) |file| {
        return common.CompilerSettings.init(allocator, file, workingDir);
    } else {
        std.log.info("jaslc expects an input file.", .{});
        return error.NoSourceFile;
    }
}

fn printHeader() void {
    std.log.info(
        "The JASL Compiler:" ++
        "\n\tVersion: " ++ common.JASL_VERSION,
        .{}
    );
}

fn printHelp() void {
    printHeader();
    std.log.info(
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
