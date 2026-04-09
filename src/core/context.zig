const std = @import("std");
const defines = @import("defines.zig");
const collections = @import("../util/collections.zig");
const threading = @import("../util/threading.zig");
const cli = @import("cli.zig");
const log = @import("log.zig");

const CompilerError = @import("common.zig").CompilerError;
const Lexer = @import("../lexer/lexer.zig");
const CompilerSettings = @import("settings.zig");
const Parser = @import("../parser/parser.zig");
const Prepass = @import("../parser/prepass.zig");

/// Central database of compilation
/// - Assumes there is a single AST and
/// a single token list per file.
/// - Hence file indices are also token
/// and ast indices.
const Self = @This();

const FileNameMap = std.ArrayList([]const u8);
const FileMap = std.ArrayList([]const u8);
const TokenMap = std.ArrayList(Lexer.TokenList.Slice);
const ASTMap = std.ArrayList(Parser.AST);
const ResolveMap = std.StringHashMapUnmanaged(defines.FilePtr);

// Source Files
filenameMap: FileNameMap,
fileMap: FileMap,
resolved: ResolveMap,

// Tokens
tokenMap: TokenMap,

// ASTs
astMap: ASTMap,

arena: std.heap.ArenaAllocator,

lock: threading.OnlyIfThreading(defines.Lock),

counts: struct {
    topLevel: u32 = 0,
    modules: u32 = 0,
    tokens: u32 = 0,
    expressions: u32 = 0,
    statements: u32 = 0,
    extras: u32 = 0,
},

settings: CompilerSettings,

pub fn init(baseAllocator: std.mem.Allocator) CompilerError!Self {
    var arena = std.heap.ArenaAllocator.init(baseAllocator);
    const allocator = arena.allocator();

    const settings = cli.parseCLI(allocator) catch |err| {
        log.err("Couldn't parse CLI input.", .{});
        return err;
    };
    settings.print(baseAllocator);

    var resolved = ResolveMap.empty;
    resolved.ensureTotalCapacity(allocator, 512) catch return error.AllocatorFailure;

    return .{
        .filenameMap = FileNameMap.initCapacity(allocator, 512) catch return error.AllocatorFailure,
        .fileMap = FileMap.initCapacity(allocator, 512) catch return error.AllocatorFailure,
        .tokenMap = TokenMap.initCapacity(allocator, 512) catch return error.AllocatorFailure,
        .astMap = ASTMap.initCapacity(allocator, 512) catch return error.AllocatorFailure,
        .arena = arena,
        .lock = if (defines.threading) .{} else {},
        .resolved = resolved,
        .settings = settings,
        .counts = .{},
    };
}

pub fn deinit(self: *Self) void {
    self.arena.deinit();
}

pub fn openRead(self: *Self, file: []const u8) CompilerError!defines.FilePtr {
    const path = try self.realpath(file);

    {
        if (defines.threading) {
            self.lock.lockShared();
            defer self.lock.unlockShared();
        }
        if (self.resolved.get(path)) |id| {
            return id;
        }
    }

    if (defines.threading) {
        self.lock.lock();
        defer self.lock.unlock();
    }

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

pub fn getFile(self: *Self, file: defines.FilePtr) []const u8 {
    if (defines.threading) {
        self.lock.lockShared();
        defer self.lock.unlockShared();
    }

    return self.fileMap.items[file];
}

pub fn getFileName(self: *Self, file: defines.FilePtr) []const u8 {
    if (defines.threading) {
        self.lock.lockShared();
        defer self.lock.unlockShared();
    }

    return self.filenameMap.items[file];
}

pub fn registerTokens(self: *Self, tokens: Lexer.TokenList.Slice) CompilerError!defines.TokenPtr {
    if (defines.threading) {
        self.lock.lock();
        defer self.lock.unlock();
    }

    self.counts.tokens += tokens.len;

    self.tokenMap.append(self.arena.allocator(), try collections.deepCopy(tokens, self.arena.allocator())) catch return error.AllocatorFailure;

    return @intCast(self.tokenMap.items.len - 1);
}

pub fn getTokens(self: *Self, tokens: defines.TokenPtr) Lexer.TokenList.Slice {
    if (defines.threading) {
        self.lock.lockShared();
        defer self.lock.unlockShared();
    }

    return self.tokenMap.items[tokens];
}

pub fn registerAST(self: *Self, ast: Parser.AST) CompilerError!defines.ASTPtr {
    if (defines.threading) {
        self.lock.lock();
        defer self.lock.unlock();
    }

    self.counts.modules += 1;
    self.counts.expressions += ast.expressions.len;
    self.counts.statements += ast.statements.len;
    self.counts.extras += @intCast(ast.extra.len);

    self.astMap.append(self.arena.allocator(), try collections.deepCopy(ast, self.arena.allocator())) catch return error.AllocatorFailure;

    return @intCast(self.astMap.items.len - 1);
}

pub fn getAST(self: *Self, ast: defines.ASTPtr) Parser.AST {
    if (defines.threading) {
        self.lock.lockShared();
        defer self.lock.unlockShared();
    }

    return self.astMap.items[ast];
}

pub fn registerModule(self: *Self, module: *const Prepass.Module) void {
    if (defines.threading) {
        self.lock.lock();
        defer self.lock.unlock();
    }

    self.counts.topLevel += module.symbols.len;
}

pub fn isProcessed(self: *Self, file: []const u8) bool {
    if (defines.threading) {
        self.lock.lockShared();
        defer self.lock.unlockShared();
    }

    return self.resolved.contains(file);
}

pub fn realpath(self: *Self, file: []const u8) CompilerError![]const u8 {
    if (defines.threading) {
        self.lock.lock();
        defer self.lock.unlock();
    }

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var allocator = std.heap.FixedBufferAllocator.init(&buf);

    var path: []const u8 = undefined;

    path = std.fs.realpathAlloc(allocator.allocator(), file) catch pblk: {
        loop: for (self.settings.includeDirs) |dir| {
            path = std.fs.path.join(allocator.allocator(), &.{dir, file}) catch return error.AllocatorFailure;
            defer allocator.allocator().free(path);

            break :pblk
                std.fs.realpathAlloc(allocator.allocator(), path)
                    catch continue :loop;
        }

        return error.FileNotFound;
    };

    return self.arena.allocator().dupe(u8, path) catch error.AllocatorFailure;
}

pub fn getFileId(self: *Self, file: []const u8) defines.FilePtr {
    if (defines.threading) {
        self.lock.lockShared();
        defer self.lock.unlockShared();
    }

    return
        if (self.resolved.get(file)) |f| f
        else 0;
}
