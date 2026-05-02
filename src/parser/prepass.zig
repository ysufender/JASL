const std = @import("std");
const common = @import("../core/common.zig");
const defines = @import("../core/defines.zig");
const collections = @import("../util/collections.zig");

const Lexer = @import("../lexer/lexer.zig");
const Parser = @import("parser.zig");
const Resolver = @import("../typechecker/resolver.zig");

const Context = common.CompilerContext;
const Error = common.CompilerError;

/// Contains both public and private top level
/// symbols.
pub const Module = struct {
    pub const Symbol = struct {
        name: defines.TokenPtr,
        value: defines.StatementPtr,
        type: defines.ExpressionPtr,
        public: bool,
    };

    /// namespace of the module
    name: []const u8,

    /// Also file and token list index
    dataIndex: defines.Offset,

    symbolPtrs: SymbolMap,
    symbols: SymbolList,
    dependencies: DependencyList,

    pub fn print(prepasser: *const Module, context: *Context) void {
        const ast = context.getAST(prepasser.dataIndex);
        std.debug.print("\nModule {s}:\n", .{prepasser.name});
        std.debug.print("\tFile: {s}\n", .{context.getFileName(prepasser.dataIndex)});
        std.debug.print("\tAST:\n", .{});
        ast.print(context);
        std.debug.print("\tDependencies:\n", .{});
        for (prepasser.dependencies.items[0..@min(16, prepasser.dependencies.items.len)]) |dependency| {
            std.debug.print("\t\t{s}\n", .{dependency});
        }
        std.debug.print("\tSymbols:\n", .{});
        for (prepasser.symbols.items(.name), 0..) |symbol, i| {
            std.debug.print("\t\t{s}{s}\n", .{
                if (prepasser.symbols.items(.public)[i]) "pub " else "",
                context.getTokens(ast.tokens).get(symbol).lexeme(context, prepasser.dataIndex)
            });
        }
    }
};

pub const ModuleList = struct {
    pub const List = collections.MultiArrayList(Module);
    pub const Map = std.StringHashMapUnmanaged(u32);

    modules: List,
    ids: Map,

    pub fn init(allocator: std.mem.Allocator, cap: u32) Error!ModuleList {
        var ids = Map.empty;

        ids.ensureTotalCapacity(allocator, cap) catch return error.AllocatorFailure;

        return .{
            .modules = try List.init(allocator, cap),
            .ids = ids,
        };
    }

    pub fn get(prepasser: *const ModuleList, name: []const u8) defines.ModulePtr {
        return prepasser.ids.get(name).?;
    }

    pub fn getItem(prepasser: *const ModuleList, name: []const u8, comptime field: std.meta.FieldEnum(Module)) @FieldType(Module, @tagName(field)) {
        return prepasser.modules.items(field)[prepasser.ids.get(name).?];
    }

    pub fn dupe(prepasser: *const ModuleList, allocator: std.mem.Allocator) Error!ModuleList {
        return .{
            .modules = try collections.deepCopy(prepasser.modules.mutableSlice(), allocator),
            .ids= try collections.deepCopy(prepasser.ids, allocator),
        };
    }
};

pub const SymbolList = collections.MultiArrayList(Module.Symbol);
pub const SymbolMap = std.StringHashMapUnmanaged(defines.SymbolPtr);
pub const ModuleMap = std.StringHashMapUnmanaged(defines.ModulePtr);
pub const DependencyList = std.ArrayList([]const u8);

const Prepass = @This();

initial: *const Parser.AST,
arena: std.heap.ArenaAllocator,

/// Maps the module names (scoping::expressions::mhm) to ModulePtr's
modules: ModuleList,
context: *Context,

/// Uses multithreaded allocator under the hood
pub fn init(context: *Context, initial: defines.ASTPtr, allocator: std.mem.Allocator) Error!Prepass {
    var arena = std.heap.ArenaAllocator.init(allocator);

    return .{
        .initial = context.getAST(initial),
        .context = context,
        .modules = try ModuleList.init(arena.allocator(), 128),
        .arena = arena,
    };
}

/// Returns a module list slice containing all modules. Releases the ownership.
pub fn prepass(prepasser: *Prepass, allocator: std.mem.Allocator) Error!ModuleList {
    defer prepasser.arena.deinit();

    const bname: []const u8 = "builtin";
    const builtin = try prepasser.modules.modules.addOne(allocator);
    prepasser.modules.modules.set(builtin, .{
        .name = try collections.deepCopy(bname, allocator), 
        .dataIndex = 0,
        .dependencies = .empty,
        .symbolPtrs = .empty,
        .symbols = try .init(allocator, 0),
    });
    prepasser.modules.ids.putAssumeCapacityNoClobber(bname, builtin);

    try prepasser.prepassImpl(prepasser.initial, "root");

    for (1..prepasser.modules.modules.len) |i| {
        prepasser.modules.modules.items(.dependencies)[i].shrinkAndFree(
            prepasser.arena.allocator(),
            prepasser.modules.modules.items(.dependencies)[i].items.len
        );
    }

    return collections.deepCopy(prepasser.modules, allocator);
}

/// Threaded recursive prepassing. Uses mutexes.
fn prepassImpl(prepasser: *Prepass, ast: *const Parser.AST, name: []const u8) Error!void {
    const tokens = prepasser.context.getTokens(ast.tokens);
    const allocator = prepasser.arena.allocator();

    var file = Module{
        .dataIndex = tokens.items(.start)[0],
        .name = name,
        .dependencies = DependencyList.initCapacity(allocator, @max(tokens.len / 32, 16)) catch |e| return e,
        .symbolPtrs = .empty,
        .symbols = SymbolList.init(allocator, @max(tokens.len / 16, 16)) catch |e| return e,
    };

    file.symbolPtrs.ensureTotalCapacity(allocator, @max(tokens.len / 16, 16)) catch |e| return e;

    var lastErr: ?Error = null;
    var errc: u32 = 0;

    var statement: Parser.Statement = undefined;
    var first = true;
    var stmt: u32 = 0;
    statementLoop: while (stmt < ast.statementMask.len) {
        if (errc == prepasser.context.settings.maxErr) {
            prepasser.report("Too many errors, aborting the prepass of module '{s}'\n", .{
                name
            }, file.dataIndex, null);

            break :statementLoop;
        }

        if (first) {
            first = false;
            statement = ast.statements.get(ast.statementMask[stmt]);
        }

        case: switch (statement.type) {
            .Import => prepasser.prepassImport(ast, statement.value, &file) catch |err| {
                lastErr = err;
                errc += 1;
                break :case;
            },
            .VariableDefinition => prepasser.prepassVariableDef(ast, tokens, &file, statement.value) catch |err| {
                lastErr = err;
                errc += 1;
                break :case;
            },
            .Mark => {
                statement = ast.statements.get(ast.extra[statement.value + 2]); 
                continue :statementLoop;
            },
            else => {
                prepasser.report(
                    "Only definitions are allowed at top-level. Received: {s}",
                    .{@tagName(statement.type)},
                    file.dataIndex,
                    null
                );

                lastErr = error.MissingStatement;
                errc += 1;
                break :case;
            },
        }

        stmt += 1;
        statement = if (stmt >= ast.statementMask.len) statement else ast.statements.get(ast.statementMask[stmt]);
    }

    if (errc > 1) {
        return error.MultipleErrors;
    }
    else if (errc == 1) {
        return lastErr.?;
    }

    const index = prepasser.modules.modules.addOne(allocator) catch |e| return e;

    prepasser.modules.ids.put(allocator, file.name, index) catch |e| return e;
    prepasser.modules.modules.set(index, file);

    if (prepasser.modules.ids.count() > defines.rehashLimit) {
        prepasser.modules.ids.rehash(std.hash_map.StringContext{});
    }

    prepasser.context.registerModule(&file);
}

fn prepassImport(
    prepasser: *Prepass,
    ast: *const Parser.AST,
    stmt: defines.OpaquePtr,
    file: *Module,
) Error!void {
    const module = getModuleName(stmt, ast, prepasser.context);
    file.dependencies.append(prepasser.arena.allocator(), module)
        catch return error.AllocatorFailure;

    const path = getModulePathWithExtension(prepasser.arena.allocator(), stmt, ast, prepasser.context) catch |err| {
        prepasser.report("Couldn't get module path for {s}: {s}.",
            .{module, @errorName(err)},
            file.dataIndex,
            if (ast.expressions.items(.type)[ast.extra[stmt]] == .Identifier)
                ast.expressions.items(.value)[ast.extra[stmt]]
            else
                ast.extra[ast.expressions.items(.value)[ast.extra[stmt]] + 1],
        );

        return err;
    };

    if (prepasser.context.isProcessed(path)) {
        return;
    }

    var lexer = Lexer.init(prepasser.arena.allocator(), prepasser.context, path) catch |err| {
        prepasser.report("Couldn't scan module at path {s}.", .{path}, prepasser.context.getFileId(path),
            if (ast.expressions.items(.type)[ast.extra[stmt]] == .Identifier)
                ast.expressions.items(.value)[ast.extra[stmt]]
            else
                ast.extra[ast.expressions.items(.value)[ast.extra[stmt]] + 1]
        );

        return err;
    };

    const moduleTokens = lexer.lex() catch |err| {
        prepasser.report("Couldn't scan module at path {s}.", .{path}, file.dataIndex,
            if (ast.expressions.items(.type)[ast.extra[stmt]] == .Identifier)
                ast.expressions.items(.value)[ast.extra[stmt]]
            else
                ast.extra[ast.expressions.items(.value)[ast.extra[stmt]] + 1]
        );

        return err;
    };

    var prs = Parser.init(prepasser.arena.allocator(), prepasser.context, moduleTokens) catch |err| {
        prepasser.report("Couldn't parse module at path {s}.", .{path}, file.dataIndex,
            if (ast.expressions.items(.type)[ast.extra[stmt]] == .Identifier)
                ast.expressions.items(.value)[ast.extra[stmt]]
            else
                ast.extra[ast.expressions.items(.value)[ast.extra[stmt]] + 1]
        );

        return err;
    };

    const imported = prs.parse() catch |err| {
        prepasser.report("Couldn't parse module at path {s}.", .{path}, file.dataIndex,
            if (ast.expressions.items(.type)[ast.extra[stmt]] == .Identifier)
                ast.expressions.items(.value)[ast.extra[stmt]]
            else
                ast.extra[ast.expressions.items(.value)[ast.extra[stmt]] + 1]
        );

        return err;
    };

    return prepasser.prepassImpl(prepasser.context.getAST(imported), module);
}

fn prepassVariableDef(
    prepasser: *Prepass,
    ast: *const Parser.AST,
    tokens: *const Lexer.TokenList.Slice,
    file: *Module,
    stmt: defines.OpaquePtr,
) Error!void {
    const signature = ast.extra[stmt];

    const sig = ast.signatures.get(signature);
    const sigName = tokens.get(sig.name).lexeme(prepasser.context, file.dataIndex);

    for (Resolver.builtins) |builtin| {
        if (std.mem.eql(u8, builtin, sigName)) {
            prepasser.report("Given symbol '{s}' collides with the builtin '{s}'.", .{
                sigName, sigName,
            }, file.dataIndex, sig.name);
            return error.DuplicateSymbol;
        }
    }

    const idx = file.symbols.addOne(prepasser.arena.allocator()) catch
        return error.AllocatorFailure;

    const res = file.symbolPtrs.getOrPut(prepasser.arena.allocator(), sigName) catch
        return error.AllocatorFailure;

    if (res.found_existing) {
        prepasser.report("Given symbol '{s}' collides with the previous definition of '{s}'.",
            .{sigName, sigName},
            file.dataIndex,
            sig.name,
        );

        return error.DuplicateSymbol;
    }

    res.value_ptr.* = idx;

    file.symbols.set(idx, .{
        .public = sig.public,
        .name = sig.name,
        .value = stmt,
        .type = sig.type,
    });
}

fn getModulePathWithExtension(allocator: std.mem.Allocator, id: u32, ast: *const Parser.AST, context: *Context) Error![]const u8 {
    return context.realpath(
        std.fmt.allocPrint(allocator, "{s}.jasl", .{
            try getModulePath(allocator, id, ast, context)
        }) catch return error.AllocatorFailure
    );
}

/// Returned path is owned by the allocator.
fn getModulePath(allocator: std.mem.Allocator, id: defines.ExpressionPtr, ast: *const Parser.AST, context: *Context) Error![]const u8 {
    const file = context.getTokens(ast.tokens).items(.start)[0];

    var parts = collections.ReverseStackArray([]const u8, std.fs.max_path_bytes).init();
    var current = ast.extra[id];

    while (true) {
        const expr = ast.expressions.get(current);
        switch (expr.type) {
            .Identifier => {
                const lexeme = context.getTokens(ast.tokens).get(expr.value).lexeme(context, file);
                parts.append(lexeme) catch return error.PathNameTooLong;
                break;
            },
            .Scoping => {
                const lhsExpr = ast.extra[expr.value];
                const rhsExpr = ast.extra[expr.value + 1];

                const rhsStr = context.getTokens(ast.tokens).get(rhsExpr).lexeme(context, file);
                parts.append(rhsStr) catch return error.PathNameTooLong;

                current = lhsExpr;
            },
            else => unreachable,
        }
    }

    return std.fs.path.join(allocator, parts.items) catch error.AllocatorFailure;
}

fn getModuleName(id: defines.ExpressionPtr, ast: *const Parser.AST, context: *Context) []const u8 {
    const file = context.getTokens(ast.tokens).items(.start)[0];
    const expr = ast.expressions.get(ast.extra[id]);

    const end = switch (expr.type) {
        .Identifier => context.getTokens(ast.tokens).items(.end)[expr.value],
        .Scoping => context.getTokens(ast.tokens).items(.end)[ast.extra[expr.value + 1]],
        else => unreachable,
    };
    const start = getModuleNameStartIndex(ast.extra[id], ast, context);

    return context.getFile(file)[start..end];
}

fn getModuleNameStartIndex(id: defines.ExpressionPtr, ast: *const Parser.AST, context: *Context) u32 {
    var current = id;
    var start = context.getTokens(ast.tokens).len;

    while (true) {
        const expr = ast.expressions.get(current);
        switch (expr.type) {
            .Identifier => {
                start = context.getTokens(ast.tokens).items(.start)[expr.value];
                break;
            },
            .Scoping => {
                current = ast.extra[expr.value];
            },
            else => unreachable,
        }
    }

    return start;
}

fn report(prepasser: *Prepass, comptime fmt: []const u8, args: anytype, file: u32, token: ?u32) void {
    common.log.err(fmt, args);
    if (
        prepasser.context.astMap.items.len > file
        and prepasser.context.getTokens(prepasser.context.getAST(file).tokens).len > 0
    ) {
        const t_idx = token orelse 0;
        if (t_idx < prepasser.context.getTokens(prepasser.context.getAST(file).tokens).len) {
            const tt = prepasser.context.getTokens(prepasser.context.getAST(file).tokens).get(t_idx);
            const position = tt.position(prepasser.context, file);
            common.log.err(("." ** 4) ++ " In {s} {d}:{d}", .{prepasser.context.getFileName(file), position.line, position.column});
            tt.printLocation(prepasser.arena.allocator(), prepasser.context, file, position, true);
            return;
        }
    }
    
    common.log.err(("." ** 4) ++ " In {s} (no location available)\n", .{prepasser.context.getFileName(file)});
}
