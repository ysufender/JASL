const std = @import("std");
const defines = @import("defines.zig");
const collections = @import("../util/collections.zig");
const cli = @import("cli.zig");
const log = @import("log.zig");

const CompilerError = @import("common.zig").CompilerError;
const Lexer = @import("../lexer/lexer.zig");
const CompilerSettings = @import("settings.zig");
const Parser = @import("../parser/parser.zig");
const Prepass = @import("../parser/prepass.zig");

const assert = std.debug.assert;

/// Central database of compilation
/// - Assumes there is a single AST and
/// a single token list per file.
/// - Hence file indices are also token
/// and ast indices.
const Context = @This();

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

counts: struct {
    topLevels: u32 = 0,
    modules: u32 = 0,
    tokens: u32 = 0,
    expressions: u32 = 0,
    statements: u32 = 0,
    extras: u32 = 0,

    integer: u32 = 0,
    float: u32 = 0,
    string: u32 = 0,
    bool: u32 = 0,
    types: u32 = 0,

    meta: u32 = 0,
},

settings: CompilerSettings,

pub fn init(baseAllocator: std.mem.Allocator) CompilerError!Context {
    var arena = std.heap.ArenaAllocator.init(baseAllocator);
    const allocator = arena.allocator();

    const settings = cli.parseCLI(allocator) catch |err| {
        if (err != error.Terminate) {
            log.err("Couldn't parse CLI input.", .{});
        }
        return err;
    };
    settings.print(baseAllocator);

    var resolved = ResolveMap.empty;
    resolved.ensureTotalCapacity(allocator, 512) catch return error.AllocatorFailure;

    const context = Context{
        .filenameMap = FileNameMap.initCapacity(allocator, 512) catch return error.AllocatorFailure,
        .fileMap = FileMap.initCapacity(allocator, 512) catch return error.AllocatorFailure,
        .tokenMap = TokenMap.initCapacity(allocator, 512) catch return error.AllocatorFailure,
        .astMap = ASTMap.initCapacity(allocator, 512) catch return error.AllocatorFailure,
        .arena = arena,
        .resolved = resolved,
        .settings = settings,
        .counts = .{},
    };

    return context;
}

pub fn deinit(context: *Context) void {
    context.arena.deinit();
}

pub fn openRead(context: *Context, file: []const u8) CompilerError!defines.FilePtr {
    const path = try context.realpath(file);

    if (context.resolved.get(path)) |id| {
        return id;
    }

    context.filenameMap.append(context.arena.allocator(), path) catch return error.AllocatorFailure;

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

    context.fileMap.append(
        context.arena.allocator(),
        fileReader.interface.readAlloc(context.arena.allocator(), sourceSize) catch |err| {
            log.err("Couldn't read file {s}\n\tInfo: {s}", .{path, @errorName(err)});
            return error.IOError;
        }
    ) catch return error.AllocatorFailure;

    context.resolved.putNoClobber(
        context.arena.allocator(),
        path,
        @intCast(context.fileMap.items.len - 1)
    ) catch return error.AllocatorFailure;

    return @intCast(context.fileMap.items.len - 1);
}

pub fn openWrite(file: []const u8) CompilerError!std.fs.File {
    return std.fs.createFileAbsolute(file, .{ .truncate = true }) catch {
        log.err("Couldn't open target file {s}", .{file});
        return error.IOError;
    };
}

pub fn getFile(context: *const Context, file: defines.FilePtr) []const u8 {
    assert(file < context.fileMap.items.len);
    return context.fileMap.items[file];
}

pub fn getFileName(context: *const Context, file: defines.FilePtr) []const u8 {
    assert(file < context.filenameMap.items.len);
    return context.filenameMap.items[file];
}

pub fn registerTokens(context: *Context, tokens: Lexer.TokenList.Slice) CompilerError!defines.TokenPtr {
    context.counts.tokens += tokens.len;

    context.tokenMap.append(context.arena.allocator(), try collections.deepCopy(tokens, context.arena.allocator())) catch return error.AllocatorFailure;

    return @intCast(context.tokenMap.items.len - 1);
}

pub fn getTokens(context: *const Context, tokens: defines.TokenPtr) *const Lexer.TokenList.Slice {
    assert(tokens < context.tokenMap.items.len);
    return &context.tokenMap.items[tokens];
}

pub fn registerAST(context: *Context, ast: Parser.AST) CompilerError!defines.ASTPtr {
    const ptr: defines.ASTPtr = @intCast(context.astMap.items.len);
    _ = context.astMap.addOne(context.arena.allocator()) catch return error.AllocatorFailure;

    context.counts.modules += 1;
    context.counts.expressions += ast.expressions.len;
    context.counts.statements += ast.statements.len;
    context.counts.extras += @intCast(ast.extra.len);

    context.counts.integer += ast.stats.integer;
    context.counts.float += ast.stats.float;
    context.counts.string += ast.stats.string;
    context.counts.bool += ast.stats.bool;
    context.counts.types += ast.stats.types;

    context.counts.meta += ast.stats.meta;

    context.astMap.items[ptr] = try collections.deepCopy(ast, context.arena.allocator());

    return ptr;
}

pub fn getAST(context: *const Context, ast: defines.ASTPtr) *const Parser.AST {
    assert(ast < context.astMap.items.len);
    return &context.astMap.items[ast];
}

pub fn registerModule(context: *Context, module: *const Prepass.Module) void {
    context.counts.topLevels += module.symbols.len;
}

pub fn isProcessed(context: *Context, file: []const u8) bool {
    return context.resolved.contains(file);
}

pub fn realpath(context: *Context, file: []const u8) CompilerError![]const u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var allocator = std.heap.FixedBufferAllocator.init(&buf);

    var path: []const u8 = undefined;

    path = std.fs.realpathAlloc(allocator.allocator(), file) catch pblk: {
        loop: for (context.settings.includeDirs) |dir| {
            path = std.fs.path.join(allocator.allocator(), &.{dir, file}) catch return error.AllocatorFailure;
            defer allocator.allocator().free(path);

            break :pblk
                std.fs.realpathAlloc(allocator.allocator(), path)
                    catch continue :loop;
        }

        return error.FileNotFound;
    };

    return context.arena.allocator().dupe(u8, path) catch error.AllocatorFailure;
}

pub fn getFileId(context: *Context, file: []const u8) defines.FilePtr {
    assert(context.resolved.contains(file));
    return
        if (context.resolved.get(file)) |f| f
        else unreachable;
}

pub fn stats(context: *Context) void {
    log.info("Stats:", .{});
    log.info("\tTotal Module Count:              {d}", .{context.counts.modules});
    log.info("\tTotal Top-Level Signature Count: {d}", .{context.counts.topLevels});
    log.info("\tTotal Tokens:                    {d}", .{context.counts.tokens});
    log.info("\tTotal Expressions:               {d}", .{context.counts.expressions});
    log.info("\tTotal Extras:                    {d}", .{context.counts.extras});
    log.info("", .{});

    log.info("\tProcessed Files:", .{});
    for (context.filenameMap.items) |file| {
        log.info("\t\t{s}", .{file});
    }
    log.info("", .{});
}
