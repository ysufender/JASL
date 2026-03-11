const std = @import("std");
const builtin = @import("builtin");
const common = @import("core/common.zig");
const lexer = @import("lexer/lexer.zig");
const parser = @import("parser/parser.zig");
const perfAllc = @import("util/allocator.zig");
const astPrinter = @import("parser/printer.zig");

pub fn main() !void {
    const allocator = perfAllc.performanceAllocator;

    var threadedIO = std.Io.Threaded.init(allocator);
    const io = threadedIO.io();
    defer threadedIO.deinit();

    innerMain(allocator, io) catch |err| {
        common.log.err("Compiler exited with code {d} <{s}>", .{@intFromError(err), @errorName(err)});
        return;
    };
    common.log.info("Compiler exited succesfully.", .{});
}

fn innerMain(allocator: std.mem.Allocator, io: std.Io) common.CompilerError!void {
    // Init Context
    try common.CompilerContext.init(allocator, io);

    // Open Source File
    const file = try common.CompilerContext.openRead(common.CompilerSettings.settings.inputFile);

    var scanner = try lexer.Scanner.init(allocator, file);
    const tokenList = try scanner.scanAll();

    var prs = try parser.Parser.init(tokenList.items, allocator);
    try prs.parse();

    std.log.info("Lexed {d} tokens.", .{tokenList.items.len});
    std.log.info("Parsed {d} statements.", .{prs.statementMap.len});
    std.log.info("Parsed {d} expressions.", .{prs.expressionMap.len});
    std.log.info("Parsed {d} signatures.", .{prs.signaturePool.len});
    std.log.info("Needed {d} extras.", .{prs.extra.items.len});
    std.log.info("Needed {d} scratch.", .{prs.scratch.capacity});

    if (@import("builtin").mode == .Debug) {
        var buf: [512]u8 = undefined;
        var stdout = std.fs.File.stdout().writer(&buf);
        var writer = stdout.interface;
        var prtr = astPrinter.PrettyPrinter.init(&prs, writer);
        prtr.printAll() catch return error.InternalError;
        writer.flush() catch return error.InternalError;
    }
}

//
// Tests
//

test "All Tests" {
    _ = lexer.Tests;
    _ = parser.Tests;
}
