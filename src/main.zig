const std = @import("std");
const builtin = @import("builtin");
const common = @import("core/common.zig");
const perfAllc = @import("util/allocator.zig");

const Lexer = @import("lexer/lexer.zig").Scanner;
const Parser = @import("parser/parser.zig").Parser;
const Printer = @import("parser/printer.zig").PrettyPrinter;

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

    var lexer = try Lexer.init(allocator, file);
    const tokens = try lexer.scanAll();

    var parser = try Parser.init(allocator, tokens);
    try parser.parse();

    var printer = Printer.init(&parser);
    for (parser.statementMask.items) |stmt| {
        std.debug.print("\n", .{});
        printer.printStatement(stmt) catch return error.InternalError;
        std.debug.print("\n", .{});
    }
}
