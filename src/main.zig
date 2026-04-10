const std = @import("std");
const common = @import("core/common.zig");
const perfAllc = @import("util/allocator.zig");
const collections = @import("util/collections.zig");
const defines = @import("core/defines.zig");

const Lexer = @import("lexer/lexer.zig");
const Parser = @import("parser/parser.zig");
const Prepass = @import("parser/prepass.zig");
const Dependency = @import("parser/dependency.zig");
const Resolver = @import("typechecker/resolver.zig");
const Typechecker = @import("typechecker/typechecker.zig");

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
    common.log.info("Compiler exited successfully.", .{});
}

fn innerMain(allocator: std.mem.Allocator) common.CompilerError!void {
    // Init Context
    var context = try common.CompilerContext.init(allocator);
    defer context.deinit();

    var lexer = try Lexer.init(
        allocator,
        &context,
        context.settings.inputFile,
    );
    const tokens = try lexer.lex();

    var parser = try Parser.init(
        allocator,
        &context,
        tokens,
    );
    const ast = try parser.parse();

    var prepass =
        if (defines.threading) try Prepass.init(&context, ast)
        else try Prepass.init(&context, ast, allocator);
    const modules = try prepass.prepass(allocator);

    var resolver = try Resolver.init(allocator, &context, modules);
    const resolved = try resolver.resolve(allocator);
    _ = resolved;

    if (true) {
        var depResolver = Dependency.init(&context, &modules);
        const dependenciesList = try depResolver.generate(allocator);

        context.stats();

        var miterator = modules.modules.iterator();
        while (miterator.next()) |mod| {
            mod.print(&context);
        }

        common.log.info("Dependency Graph:", .{});
        var diterator = try dependenciesList.iterator(allocator);
        while (diterator.next()) |dep| {
            common.log.info("\t{s}:", .{dep.name});
            for (dep.depends) |depDep| {
                common.log.info("\t\tDepends on {s} {d}", .{dependenciesList.nodes[depDep].name, depDep});
            }
        }
    }
}

pub const panic = std.debug.FullPanic(panicHandler);

fn panicHandler(msg: []const u8, trace: ?usize) noreturn {
    std.fs.File.stderr().writeAll("\nRuntime invoked panic:\n") catch {};
    std.fs.File.stderr().writeAll(msg) catch {};
    std.fs.File.stderr().writeAll("\n") catch {};

    if (trace) |traceStart| {
        std.debug.dumpCurrentStackTrace(traceStart);
    }

    std.fs.File.stderr().writeAll("\n") catch {};
    std.process.exit(1);
}
