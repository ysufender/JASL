const std = @import("std");
const common = @import("core/common.zig");
const perfAllc = @import("util/allocator.zig");
const collections = @import("util/collections.zig");
const defines = @import("core/defines.zig");
const debug = @import("debug/debug.zig");

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

    var prepass = try Prepass.init(&context, ast, allocator);
    const modules = try prepass.prepass(allocator);

    if (context.settings.printAST) {
        debug.ASTPrinter.printAST(context.getAST(ast), &context);
    }

    var resolver = try Resolver.init(allocator, &context, &modules);
    const resolved = try resolver.resolve(allocator);

    var typechecker = try Typechecker.init(allocator, &context, &modules, &resolved);
    const typechecked = try typechecker.typecheck(allocator);
    _ = typechecked;

    context.stats();
    if (false) {
        var miterator = modules.modules.iterator();
        _ = miterator.next();
        while (miterator.next()) |mod| {
            mod.print(&context);
        }

        common.log.info("", .{});
        common.log.info("Resolution Map:", .{});
        var iterator = resolved.declarations.iterator();
        while (iterator.next()) |decl| {
            const dataIndex = modules.modules.items(.dataIndex)[resolved.scopes.items(.module)[decl.scope]];
            const module = modules.modules.items(.name)[resolved.scopes.items(.module)[decl.scope]];
            common.log.info("\tFrom {s} decl {s}{s} = {d}:", .{
                module,
                if (decl.public) "pub " else "",
                context.getTokens(dataIndex)
                    .get(decl.token)
                    .lexeme(&context, dataIndex),
                decl.node,
            });
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
