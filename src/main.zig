const std = @import("std");
const common = @import("core/common.zig");
const perfAllc = @import("util/allocator.zig");
const collections = @import("util/collections.zig");
const defines = @import("core/defines.zig");
const debug = @import("debug/debug.zig");

const Lexer = @import("lexer/lexer.zig");
const Parser = @import("parser/parser.zig");
const Prepass = @import("parser/prepass.zig");
const Resolver = @import("typechecker/resolver.zig");
const Typechecker = @import("typechecker/typechecker.zig");

pub fn main(init: std.process.Init) void {
    MainProcInit = init;
    // const hugepage = null;
    var hugepage = perfAllc.PerformanceAllocator(init.gpa);
    const allocator = if (hugepage) |*alc| alc.allocator() else init.gpa;

    if (hugepage) |_| {
        common.log.debug("Using huge pages", .{});
    }

    innerMain(allocator, init) catch |err| blk: {
        switch (err) {
            error.ShouldBeImpossible => common.log.err(
                "This is a compiler bug, a part of impossible branch has been reached."
                ++ " Please inform the authors about it.", .{ }
            ),
            error.NotImplemented => common.log.err(
                "The compiler has hit an unfinished part of the codebase, stay tuned.", .{ }
            ),
            error.Terminate => break :blk,
            else => { }, 
        }

        if (@errorReturnTrace()) |trace| {
            std.debug.dumpErrorReturnTrace(@ptrCast(trace));
        }

        return common.log.err(
            "Compiler exited with code {d} <{s}>", .{
            @intFromError(err),
            @errorName(err)
        });
    };

    common.log.info("Compiler exited successfully.", .{});
}

fn innerMain(allocator: std.mem.Allocator, init: std.process.Init) common.CompilerError!void {
    var globalArena = std.heap.ArenaAllocator.init(allocator);
    const safe = globalArena.allocator();
    // const allocator = globalArena.allocator();
    defer globalArena.deinit();

    // Init Context
    var context = try common.CompilerContext.init(allocator, init);
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

    if (context.settings.hasFlag("--print-ast")) {
        debug.ASTPrinter.printAST(ast, &context);
    }

    if (context.settings.hasFlag("--parse-only")) {
        return;
    }

    var prepass = try Prepass.init(&context, ast, allocator);
    const modules = try prepass.prepass(safe);
    //const modules = try prepass.prepass(allocator);
    //defer collections.deepFree(modules, allocator) catch { };

    if (context.settings.hasFlag("--print-ast-full")) {
        debug.ASTPrinter.printASTs(&context, &modules);
    }

    var resolver = try Resolver.init(allocator, &context, &modules);
    const resolved = try resolver.resolve(safe);
    //const resolved = try resolver.resolve(allocator);
    //defer collections.deepFree(resolved, allocator) catch { };

    if (context.settings.hasFlag("--print-resolution")) {
        common.log.info("--print-resolution: Not implemented.", .{});
    }

    if (context.settings.hasFlag("--resolve-only")) {
        return;
    }

    var typechecker = try Typechecker.init(allocator, &context, &modules, &resolved);
    _ = try typechecker.typecheck(safe);

    if (context.settings.hasFlag("--typecheck-only")) {
        return;
    }

    if (false) {
        context.stats();

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

pub var MainProcInit: std.process.Init = undefined;
pub const panic = std.debug.FullPanic(panicHandler);
fn panicHandler(msg: []const u8, _: ?usize) noreturn {
    const _stderr = std.Io.File.stderr().writer(MainProcInit.io, &common.log.wbuf);
    var stderr = _stderr.interface;

    stderr.writeAll("\nRuntime invoked panic:\nInfo: ") catch {};
    stderr.writeAll(msg) catch {};
    stderr.writeAll("\n") catch {};

    if (std.debug.sys_can_stack_trace) {
        std.debug.dumpCurrentStackTrace(.{});
    }

    stderr.writeAll("\n") catch {};
    std.process.exit(1);
}
