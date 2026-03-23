const std = @import("std");
const common = @import("core/common.zig");
const perfAllc = @import("util/allocator.zig");

const Lexer = @import("lexer/lexer.zig").Scanner;
const Parser = @import("parser/parser.zig").Parser;
const Prepass = @import("parser/prepass.zig").Prepass;

pub fn main() !void {
    const allocator = perfAllc.performanceAllocator;

    innerMain(allocator) catch |err| {
        if (!@import("builtin").strip_debug_info) {
            if (@errorReturnTrace()) |trace| {
                std.debug.dumpStackTrace(trace.*);
            }
        }

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
        context.settings.inputFile,
    );
    const tokens = try lexer.scanAll();

    var parser = try Parser.init(
        allocator,
        &context,
        tokens,
    );
    const ast = try parser.parse();

    var prepass = try Prepass.init(&context, ast);
    const modules = try prepass.prepass(allocator);

    std.debug.print("Parsed {d} files.\n", .{context.fileMap.items.len});
    var iterator = modules.iterator();
    while (iterator.next()) |module| {
        module.print(&context);
    }
}
