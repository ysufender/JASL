const common = @This();

const std = @import("std");
const builtin = @import("builtin");

pub const JASL_VERSION = "0.0.1";

pub const CompilerSettings = struct {
    inputFile: []const u8,
    workingDir: []const u8,
    maxErr: u32,

    pub var settings: CompilerSettings = undefined;

    const Self = @This();

    pub fn print(self: *const Self) void {
        log.info(
            "Compilation settings\n\tInput File: {s}\n\tWorking Dir: {s}\n",
            .{self.inputFile, self.workingDir}
        );
    }
};

pub const CompilerContext = struct {
    pub var filenameMap: [512][]const u8 = undefined;
    pub var fileMap: [512][]const u8 = undefined;
    var fileCount: u32 = 0;

    var arena: std.heap.ArenaAllocator = undefined;
    var allocator: std.mem.Allocator = undefined;

    pub fn init(baseAllocator: std.mem.Allocator) !void {
        arena = std.heap.ArenaAllocator.init(baseAllocator);

        allocator = arena.allocator();

        CompilerSettings.settings = try CLI.parseCLI(allocator);
        common.CompilerSettings.settings.print();
    }

    pub fn openRead(file: []const u8) CompilerError!u32 {
        const path = try realpath(file);
        filenameMap[fileCount] = path;

        var sourceFile = std.fs.openFileAbsolute(path, .{.mode = .read_only}) catch {
            log.err("Couldn't open source file '{s}'.", .{file});
            return error.IOError;
        };
        defer sourceFile.close();

        var fileReader = sourceFile.reader(&.{});
        const sourceSize = fileReader.getSize() catch {
            log.err("Couldn't get the size of file {s}", .{path});
            return error.IOError;
        };

        fileMap[fileCount] = fileReader.interface.readAlloc(allocator, sourceSize) catch |err| {
            log.err("Couldn't read file {s}\n\tInfo: {s}", .{path, @errorName(err)});
            return error.IOError;
        };

        fileCount += 1;
        return @intCast(fileCount - 1);
    }

    pub fn openWrite(file: []const u8) CompilerError!std.fs.File {
        return std.fs.createFileAbsolute(file, .{ .truncate = true }) catch {
            log.err("Couldn't open target file {s}", .{file});
            return error.IOError;
        };
    }

    fn realpath(file: []const u8) CompilerError![]const u8 {
        return std.fs.realpathAlloc(allocator, file) catch {
            log.err("Couldn't find the file with path {s}", .{file});
            return error.IOError;
        };
    }
};

const CLI = struct {
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

    fn parseCLI(allocator: std.mem.Allocator) common.CompilerError!common.CompilerSettings {
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

                    workingDir = dir;
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
};

pub const CompilerError = error {
    MissingFlag,
    UnknownFlag,
    InternalError,
    NoSourceFile,
    IOError,
    InvalidToken,
    UnterminatedComment,
    UnterminatedStringLiteral,
    DotPrefixedNumericLiteral,
    DotPostfixedNumericLiteral,
    UnexpectedCharacter,
    AllocatorFailure,
    MissingBrace,
    MissingParenthesis,
    MissingSemicolon,
    MissingComma,
    MissingArrow,
    MissingTypeSpecifier,
    MissingIdentifier,
    MissingColon,
    MissingAssignment,
    MissingBracket,
    MissingBranch,
    MissingStatement,
    MultipleErrors,
    EOS,
};

pub const log = struct {
    pub const info = if (builtin.is_test) emptyLog else std.log.info;
    pub const warn = if (builtin.is_test) emptyLog else std.log.warn;
    pub const err = if (builtin.is_test) emptyLog else std.log.err;

    fn emptyLog(comptime _: []const u8, _: anytype) void { }
};
