const common = @This();

const std = @import("std");
const builtin = @import("builtin");
const lexer = @import("../lexer/lexer.zig");
const parser = @import("../parser/parser.zig");

const Lock = std.Thread.RwLock;

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
    const Self = @This();

    const FileNameMap = std.ArrayList([]const u8);
    const FileMap = std.ArrayList([]const u8);
    const TokenMap = std.ArrayList(lexer.TokenList.Slice);
    const ASTMap = std.ArrayList(parser.AST);
    const ResolveMap = std.StringHashMapUnmanaged(u32);

    // Source Files
    filenameMap: FileNameMap,
    fileMap: FileMap,
    resolved: ResolveMap,

    // Tokens
    tokenMap: TokenMap,

    // ASTs
    astMap: ASTMap,

    arena: std.heap.ArenaAllocator,
    lock: std.Thread.RwLock,

    pub fn init(baseAllocator: std.mem.Allocator) CompilerError!Self {
        var arena = std.heap.ArenaAllocator.init(baseAllocator);
        const allocator = arena.allocator();

        CompilerSettings.settings = try CLI.parseCLI(allocator);
        common.CompilerSettings.settings.print();

        var resolved = ResolveMap.empty;
        resolved.ensureTotalCapacity(allocator, 512) catch return error.AllocatorFailure;

        return .{
            .filenameMap = FileNameMap.initCapacity(allocator, 512) catch return error.AllocatorFailure,
            .fileMap = FileMap.initCapacity(allocator, 512) catch return error.AllocatorFailure,
            .tokenMap = TokenMap.initCapacity(allocator, 512) catch return error.AllocatorFailure,
            .astMap = ASTMap.initCapacity(allocator, 512) catch return error.AllocatorFailure,
            .arena = arena,
            .lock = .{},
            .resolved = resolved,
        };
    }

    pub fn openRead(self: *Self, file: []const u8) CompilerError!u32 {
        const path = try self.realpath(file);

        // pre-check
        {
            self.lock.lockShared();
            defer self.lock.unlockShared();

            if (self.resolved.get(path)) |id| {
                return id;
            }
        }

        self.lock.lock();
        defer self.lock.unlock();

        self.filenameMap.append(self.arena.allocator(), path) catch return error.AllocatorFailure;

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

        self.fileMap.append(
            self.arena.allocator(),
            fileReader.interface.readAlloc(self.arena.allocator(), sourceSize) catch |err| {
                log.err("Couldn't read file {s}\n\tInfo: {s}", .{path, @errorName(err)});
                return error.IOError;
            }
        ) catch return error.AllocatorFailure;

        self.resolved.putNoClobber(
            self.arena.allocator(),
            path,
            @intCast(self.fileMap.items.len - 1)
        ) catch return error.AllocatorFailure;

        return @intCast(self.fileMap.items.len - 1);
    }

    pub fn openWrite(file: []const u8) CompilerError!std.fs.File {
        return std.fs.createFileAbsolute(file, .{ .truncate = true }) catch {
            log.err("Couldn't open target file {s}", .{file});
            return error.IOError;
        };
    }

    pub fn getFile(self: *Self, file: u32) []const u8 {
        self.lock.lockShared();
        defer self.lock.unlockShared();

        return self.fileMap.items[file];
    }

    pub fn getFileName(self: *Self, file: u32) []const u8 {
        self.lock.lockShared();
        defer self.lock.unlockShared();

        return self.filenameMap.items[file];
    }

    pub fn registerTokens(self: *Self, tokens: lexer.TokenList.Slice) CompilerError!u32 {
        self.lock.lock();
        defer self.lock.unlock();

        self.tokenMap.append(self.arena.allocator(), tokens) catch return error.AllocatorFailure;

        return @intCast(self.tokenMap.items.len - 1);
    }

    pub fn getTokens(self: *Self, tokens: u32) *const lexer.TokenList.Slice {
        self.lock.lockShared();
        defer self.lock.unlockShared();

        return &self.tokenMap.items[tokens];
    }

    pub fn registerAST(self: *Self, ast: parser.AST) CompilerError!u32 {
        self.lock.lock();
        defer self.lock.unlock();

        self.astMap.append(self.arena.allocator(), ast) catch return error.AllocatorFailure;

        return @intCast(self.astMap.items.len - 1);
    }

    pub fn getAST(self: *Self, ast: u32) *const parser.AST {
        self.lock.lockShared();
        defer self.lock.unlockShared();

        return &self.astMap.items[ast];
    }

    fn realpath(self: *Self, file: []const u8) CompilerError![]const u8 {
        self.lock.lock();
        defer self.lock.unlock();

        return std.fs.realpathAlloc(self.arena.allocator(), file) catch {
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
