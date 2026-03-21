const std = @import("std");
const common = @import("core/common.zig");
const perfAllc = @import("util/allocator.zig");

const Lexer = @import("lexer/lexer.zig").Scanner;
const Parser = @import("parser/parser.zig").Parser;
const Printer = @import("parser/printer.zig").PrettyPrinter;
const Prepass = @import("parser/prepass.zig").Prepass;

pub fn main() !void {
    const allocator = perfAllc.performanceAllocator;

    innerMain(allocator) catch |err| {
        return common.log.err("Compiler exited with code {d} <{s}>", .{@intFromError(err), @errorName(err)});
    };
    common.log.info("Compiler exited succesfully.", .{});
}

fn innerMain(allocator: std.mem.Allocator) common.CompilerError!void {
    // Init Context
    var context = try common.CompilerContext.init(allocator);

    var lexer = try Lexer.init(
        allocator,
        &context,
        common.CompilerSettings.settings.inputFile,
    );
    const tokens = try lexer.scanAll();

    var parser = try Parser.init(
        allocator,
        &context,
        tokens,
    );

    const ast = try parser.parse();

    var prepass = try Prepass.init(allocator, &context, ast);
    _ = try prepass.prepass();
}
