const std = @import("std");
const builtin = @import("builtin");
const common = @import("core/common.zig");
const lexer = @import("lexer/lexer.zig");
const parser = @import("parser/parser.zig");
const perfAllc = @import("util/allocator.zig");
const astPrinter = @import("parser/printer.zig");

pub fn main() !void {
    const allocator = perfAllc.performanceAllocator;

    innerMain(allocator) catch |err| {
        common.log.err("Compiler exited with code {d} <{s}>", .{@intFromError(err), @errorName(err)});
        return;
    };
    common.log.info("Compiler exited succesfully.", .{});
}

fn innerMain(allocator: std.mem.Allocator) common.CompilerError!void {
    // Init Context
    try common.CompilerContext.init(allocator);

    // Open Source File
    const file = try common.CompilerContext.openRead(common.CompilerSettings.settings.inputFile);

    var scanner = try lexer.Scanner.init(allocator, file);
    const tokens = try scanner.scanAll();

    var prs = try parser.Parser.init(allocator, tokens);
    try prs.parse();

    std.log.info("Lexed {d} tokens.", .{tokens.len});
    std.log.info("Parsed {d} statements.", .{prs.statementMap.len});
    std.log.info("Parsed {d} expressions.", .{prs.expressionMap.len});
    std.log.info("Parsed {d} signatures.", .{prs.signaturePool.len});
    std.log.info("Needed {d} extras.", .{prs.extra.items.len});
    std.log.info("Needed {d} scratch.", .{prs.scratch.capacity});
}

//
// Tests
//

test "All Tests" {
    _ = lexer.Tests;
    _ = parser.Tests;
}
