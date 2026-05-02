const std = @import("std");
const common = @import("../core/common.zig");
const defines = @import("../core/defines.zig");
const collections = @import("../util/collections.zig");

const Lexer = @import("../lexer/lexer.zig");
const Parser = @import("../parser/parser.zig");
const Prepass = @import("../parser/prepass.zig");

const MultiArrayList = collections.MultiArrayList;
const ModuleList = Prepass.ModuleList;
const Error = common.CompilerError;
const Context = common.CompilerContext;
const Allocator = std.mem.Allocator;
const Arena = std.heap.ArenaAllocator;

const assert = std.debug.assert;

pub const ScopeList = MultiArrayList(Scope);
pub const DeclarationList = MultiArrayList(Declaration);
pub const LookupMap = collections.HashMap(LookupKey([]const u8), defines.DeclPtr);
pub const ResolutionMap = collections.HashMap(ResolutionKey, defines.DeclPtr);

pub const Scope = struct {
    pub const Kind = enum {
        Module,
        Block,
        Enum,
        Struct,
        Union,
    };

    parent: ?defines.ScopePtr,
    module: defines.ModulePtr,
    kind: Kind,
};

pub const Declaration = struct {
    pub const Kind = enum {
        Variable,
        Capture,
        Parameter,
        Namespace,
        Field,
        Builtin,
    };

    scope: defines.ScopePtr,
    token: defines.TokenPtr,
    node: defines.StatementPtr,
    type: defines.ExpressionPtr,
    topLevel: bool,
    kind: Kind,
    public: bool,
};

pub const ResolutionKey = struct {
    file: defines.FilePtr,
    expr: defines.ExpressionPtr,
};

pub fn LookupKey(comptime T: type) type {
    return struct {
        scope: defines.OpaquePtr,
        name: T,
    };
}

pub fn LookupContext(comptime T: type) type {
    return struct {
        const Self = @This();
        pub const Key = LookupKey(T);

        pub fn hash(_: Self, key: Key) u64 { 
            var hasher = std.hash.Wyhash.init(0);
            std.hash.autoHashStrat(&hasher, key, .DeepRecursive);
            return hasher.final();
        }

        pub fn eql(_: Self, a: Key, b: Key) bool {
            return
                a.scope == b.scope
                and
                switch (@typeInfo(T)) {
                    .Pointer => |ptr| std.mem.eql(ptr.child, a.name, b.name),
                    else => a.name == b.name,
                };
        }
    };
}

pub const Resolution = struct {
    resolutionMap: ResolutionMap,
    declarations: DeclarationList.Slice,
    lookup: LookupMap,
    scopes: ScopeList.Slice,

    pub fn getDecl(resolution: *const Resolution, key: defines.DeclPtr) Declaration {
        return resolution.declarations.get(key);
    }

    pub fn findDecl(resolution: *const Resolution, key: ResolutionKey) defines.DeclPtr {
        return resolution.resolutionMap.get(key).?;
    }
};

const Resolver = @This();

arena: Arena,
context: *Context,
scopes: ScopeList,
lookup: LookupMap,
decls: DeclarationList,
resolved: ResolutionMap,
currentScope: defines.ScopePtr,
modules: *const ModuleList,
lastToken: defines.TokenPtr,

pub fn init(gpa: Allocator, context: *Context, modules: *const ModuleList) Error!Resolver {
    var arena = Arena.init(gpa);
    const allocator = arena.allocator();

    const scopeCap = (context.counts.statements / 4) + context.counts.modules;
    const declCap = (context.counts.expressions / 8) + context.counts.topLevels;

    var scopes = try ScopeList.init(allocator, scopeCap + 1);
    var decls = try DeclarationList.init(allocator, declCap + builtins.len);
    var lookup = LookupMap.empty;
    var reso = ResolutionMap.empty;

    lookup.ensureTotalCapacity(allocator, declCap) catch return error.AllocatorFailure;
    reso.ensureTotalCapacity(allocator, declCap) catch return error.AllocatorFailure;

    const builtin = try scopes.addOne(allocator);
    scopes.set(builtin, .{
        .parent = null,
        .module = modules.ids.get("builtin").?,
        .kind = .Module,
    });

    for (builtins, 0..) |b, i| {
        const decl = try decls.addOne(allocator);
        decls.set(decl, .{
            .kind = .Builtin,
            .scope = builtin,
            .public = true,
            .token = 0,
            .node = @intCast(i),
            .type = @intCast(i),
            .topLevel = true,
        });

        lookup.putNoClobber(allocator, .{ .name = b, .scope = builtin }, decl)
            catch return error.AllocatorFailure;
    }

    var iterator = modules.modules.iterator();
    _ = iterator.next();
    while (iterator.next()) |module| {
        const tokens = context.getTokens(module.dataIndex);

        const scope = try scopes.addOne(allocator);
        scopes.set(scope, .{
            .parent = builtin,
            .module = iterator.idx - 1,
            .kind = .Module,
        });

        var siterator = module.symbols.iterator();
        while (siterator.next()) |symbol| {
            const name = tokens.get(symbol.name).lexeme(context, module.dataIndex);

            const decl = try decls.addOne(allocator);
            decls.set(decl, .{
                .scope = scope,
                .kind = .Variable,
                .public = symbol.public,
                .token = symbol.name,
                .node = symbol.value,
                .type = symbol.type,
                .topLevel = true,
            });

            lookup.putNoClobber(allocator, .{
                .scope = scope,
                .name = name,
            }, decl) catch return error.AllocatorFailure;
        }
    }

    return .{
        .context = context,
        .scopes = scopes,
        .lookup = lookup,
        .decls = decls,
        .resolved = reso,
        .modules = modules,
        .currentScope = 1,
        .lastToken = 0,
        .arena = arena,
    };
}

pub fn resolve(resolver: *Resolver, allocator: Allocator) Error!Resolution {
    defer resolver.arena.deinit();

    var errCount: u32 = 0;
    var lastErr: common.CompilerError = undefined;

    const modules = resolver.scopes.len;
    for (1..modules) |i| {
        resolver.currentScope = @intCast(i);
        resolver.resolveModule() catch |err| {
            errCount += 1;
            lastErr = err;
            if (errCount == resolver.context.settings.maxErr) {
                common.log.err("Too many errors, aborting compilation.\n", .{});
                return err;
            }
        };
    }

    if (errCount > 1) {
        lastErr = error.MultipleErrors;
    }

    if (errCount > 0) {
        return lastErr;
    }

    return collections.deepCopy(Resolution{
        .resolutionMap = resolver.resolved,
        .declarations = resolver.decls.slice(),
        .scopes = resolver.scopes.slice(),
        .lookup = resolver.lookup,
    }, allocator);
}

fn resolveModule(resolver: *Resolver) Error!void {
    const module = resolver.modules.modules.items(.name)[resolver.scopes.items(.module)[resolver.currentScope]];

    const kind = resolver.scopes.items(.kind)[resolver.currentScope];
    if (kind != .Module) {
        return error.UnexpectedScope;
    }

    var errCount: u32 = 0;
    var lastErr: common.CompilerError = undefined;

    const ast = resolver.context.getAST(resolver.dataIndex());
    const allocator = resolver.arena.allocator();
    _ = allocator;

    for (ast.statementMask) |item| {
        resolver.resolveStatement(item, true) catch |err| {
            errCount += 1;
            lastErr = err;
            common.log.err("Error: {d} <{s}>\n", .{ @intFromError(err), @errorName(err) });
            if (errCount == resolver.context.settings.maxErr) {
                common.log.err("Too many errors, aborting current module '{s}'.\n", .{module});
                return err;
            }
        };
    }

    if (errCount > 1) {
        lastErr = error.MultipleErrors;
    }

    if (errCount > 0) {
        return lastErr;
    }
}

fn resolveStatement(resolver: *Resolver, stmt: defines.StatementPtr, topLevel: bool) Error!void {
    const allocator = resolver.arena.allocator();
    const ast = resolver.context.getAST(resolver.dataIndex());
    const tokens = resolver.context.getTokens(ast.tokens);

    const statement = ast.statements.get(stmt);
    switch (statement.type) {
        .Block => {
            const stmts = defines.Range{
                .start = ast.extra[statement.value],
                .end = ast.extra[statement.value + 1]
            };

            const block = try resolver.scopes.addOne(allocator);
            resolver.scopes.set(block, .{
                .module = resolver.scopes.items(.module)[resolver.currentScope],
                .parent = resolver.currentScope,
                .kind = .Block,
            });

            const previous = resolver.currentScope;
            defer resolver.currentScope = previous;
            resolver.currentScope = block;

            for (stmts.start..stmts.end) |stmtPtrPtr| {
                const stmtPtr = ast.extra[stmtPtrPtr];
                try resolver.resolveStatement(stmtPtr, false);
            }
        },
        .Conditional => {
            const condition = ast.extra[statement.value];
            try resolver.resolveExpression(condition);

            const body = ast.extra[statement.value + 1];
            try resolver.resolveStatement(body, false);

            const hasElse = ast.extra[statement.value + 2] == 1;
            if (hasElse) {
                const elseBody = ast.extra[statement.value + 3];
                try resolver.resolveStatement(elseBody, false);
            }
        },
        .Switch => {
            const item = ast.extra[statement.value];
            try resolver.resolveExpression(item);

            const cases = defines.Range{
                .start = ast.extra[statement.value + 1],
                .end = ast.extra[statement.value + 2],
            };

            var case: u32 = cases.start;
            while (case < cases.end) : (case += 3) {
                const pattern = ast.extra[case];

                if (pattern != 0) {
                    try resolver.resolveExpression(pattern);
                }

                const caseScope = try resolver.scopes.addOne(allocator);
                resolver.scopes.set(caseScope, .{
                    .module = resolver.scopes.items(.module)[resolver.currentScope],
                    .parent = resolver.currentScope,
                    .kind = .Block,
                });

                const previous = resolver.currentScope;
                defer resolver.currentScope = previous;
                resolver.currentScope = caseScope;

                const capture = ast.extra[case + 1];
                if (capture != 0) {
                    const decl = try resolver.decls.addOne(allocator);
                    resolver.decls.set(decl, .{
                        .scope = resolver.currentScope,
                        .kind = .Capture,
                        .public = false,
                        .token = capture,
                        .node = item,
                        .type = 0,
                        .topLevel = false,
                    });

                    const lexeme = tokens.get(capture).lexeme(resolver.context, resolver.dataIndex());
                    resolver.lookup.put(allocator, .{ .name = lexeme, .scope = resolver.currentScope }, decl)
                        catch return error.AllocatorFailure;
                }

                const body = ast.extra[case + 2];
                try resolver.resolveStatement(body, false);
            }
        },
        .While => {
            const condition = ast.extra[statement.value];
            try resolver.resolveExpression(condition);

            const body = ast.extra[statement.value + 1];
            try resolver.resolveStatement(body, false);
        },
        .Mark => {
            const marks = defines.Range{
                .start = ast.extra[statement.value],
                .end = ast.extra[statement.value + 1],
            };

            for (marks.start..marks.end) |mark| {
                try resolver.resolveExpression(ast.extra[mark]);
            }

            const marked = ast.extra[statement.value + 2];
            try resolver.resolveStatement(marked, topLevel);
        },
        .VariableDefinition => {
            const signature = ast.signatures.get(ast.extra[statement.value]);
            const initializer = ast.extra[statement.value + 1];

            if (signature.type != 0) {
                try resolver.resolveExpression(signature.type);
            }

            const decl =
                if (topLevel) try resolver.look(signature.name)
                else try resolver.decls.addOne(allocator);

            resolver.decls.set(decl, .{
                .kind = .Variable,
                .scope = resolver.currentScope,
                .public = signature.public,
                .token = signature.name,
                .node = initializer,
                .type = signature.type,
                .topLevel = topLevel,
            });

            if (topLevel) {
                return resolver.resolveExpression(initializer);
            }

            const name = tokens.get(signature.name).lexeme(resolver.context, resolver.dataIndex());
            const isPresent = resolver.lookup.getOrPut(allocator, .{ .name = name, .scope = resolver.currentScope })
                catch return error.AllocatorFailure;

            if (isPresent.found_existing) {
                resolver.report("Given symbol '{s}' collides with the previous definition of '{s}'.", .{name, name});
                return error.DuplicateSymbol;
            }

            isPresent.value_ptr.* = decl;

            try resolver.resolveExpression(initializer);
        },
        .Import => {
            const modulename = resolver.getModuleName(ast.extra[statement.value]);
            const moduleID = resolver.modules.get(modulename);
            const isAlias = ast.extra[statement.value + 1] == 1;
            const alias =
                if (isAlias) ast.extra[statement.value + 2]
                else 0;

            const decl = try resolver.decls.addOne(allocator);
            resolver.decls.set(decl, .{
                .kind = .Namespace,
                .scope = resolver.currentScope,
                .public = false,
                .token = if (isAlias) alias else ast.extra[statement.value],
                .node = moduleID,
                .type = ast.extra[statement.value],
                .topLevel = true,
            });

            const lexeme =
                if (isAlias) tokens.get(alias).lexeme(resolver.context, resolver.dataIndex())
                else modulename;

            const isPresent = resolver.lookup.getOrPut(allocator, .{ .name = lexeme, .scope = resolver.currentScope })
                catch return error.AllocatorFailure;

            if (isPresent.found_existing) {
                resolver.report("Duplicate import of '{s}'.", .{lexeme});
                return error.DuplicateSymbol;
            }

            isPresent.value_ptr.* = decl;
        },

        // Single expr statements
        .Defer, .Return, .Discard, .Expression => try resolver.resolveExpression(statement.value),

        else => {},
    }
}

fn resolveExpression(resolver: *Resolver, exprPtr: defines.ExpressionPtr) Error!void {
    const ast = resolver.context.getAST(resolver.dataIndex());
    const tokens = resolver.context.getTokens(ast.tokens);

    const allocator = resolver.arena.allocator();

    const expr = ast.expressions.get(exprPtr);
    switch (expr.type) {
        .Identifier => {
            const identifier = expr.value;
            resolver.lastToken = identifier;

            if (identifier == 0) return;

            const decl = try resolver.look(identifier);

            const status = resolver.resolved.getOrPut(allocator, .{ .file = ast.tokens, .expr = exprPtr })
                catch return error.AllocatorFailure;

            if (status.found_existing) {
                resolver.report(
                    "This is an internal compiler bug."
                    ++ " Attempt to resolve identifier '{s}', multiple times.", .{
                    tokens.get(identifier).lexeme(resolver.context, ast.tokens)
                });
                return common.debug.ShouldBeImpossible(@src());
            }

            status.value_ptr.* = decl;
        },
        .Indexing, .Assignment => {
            const lhs = ast.extra[expr.value];
            try resolver.resolveExpression(lhs);

            const rhs = ast.extra[expr.value + 1];
            try resolver.resolveExpression(rhs);
        },
        .Slicing => {
            const ptr = ast.extra[expr.value];
            try resolver.resolveExpression(ptr);

            const rangeStart = ast.extra[expr.value + 1];
            try resolver.resolveExpression(rangeStart);

            const rangeEnd = ast.extra[expr.value + 2];
            try resolver.resolveExpression(rangeEnd);
        },
        .Binary => {
            const lhs = ast.extra[expr.value];
            try resolver.resolveExpression(lhs);

            const rhs = ast.extra[expr.value + 2];
            try resolver.resolveExpression(rhs);
        },
        .Unary => {
            const rhs = ast.extra[expr.value + 1];
            try resolver.resolveExpression(rhs);
        },
        .StructDefinition => {
            const body = try resolver.scopes.addOne(allocator);
            resolver.scopes.set(body, Scope{
                .parent = resolver.currentScope,
                .module = resolver.scopes.items(.module)[resolver.currentScope],
                .kind = .Struct,
            });

            const previous = resolver.currentScope;
            defer resolver.currentScope = previous;
            resolver.currentScope = body;

            const defs = defines.Range{
                .start = ast.extra[expr.value + 2],
                .end = ast.extra[expr.value + 3],
            };

            try resolver.handleScopeDefs(defs);

            const fields = defines.Range{
                .start = ast.extra[expr.value],
                .end = ast.extra[expr.value + 1],
            };

            for (fields.start..fields.end) |fieldPtrPtr| {
                if (try resolver.resolveSignature(ast.extra[fieldPtrPtr], .Field, .Struct)) {
                    const lexeme = tokens.get(ast.signatures.get(ast.extra[fieldPtrPtr]).name).lexeme(resolver.context, resolver.dataIndex());
                    resolver.report("Given field '{s}' collides with the previous definition of '{s}'.", .{lexeme, lexeme});
                    return error.DuplicateSymbol;
                }
            }
        },
        .EnumDefinition => {
            const body = try resolver.scopes.addOne(allocator);
            resolver.scopes.set(body, Scope{
                .parent = resolver.currentScope,
                .module = resolver.scopes.items(.module)[resolver.currentScope],
                .kind = .Enum,
            });

            const previous = resolver.currentScope;
            defer resolver.currentScope = previous;
            resolver.currentScope = body;

            const defs = defines.Range{
                .start = ast.extra[expr.value + 2],
                .end = ast.extra[expr.value + 3],
            };

            try resolver.handleScopeDefs(defs);

            const fields = defines.Range{
                .start = ast.extra[expr.value],
                .end = ast.extra[expr.value + 1],
            };

            for (fields.start..fields.end) |fieldPtrPtr| {
                if (try resolver.resolveSignature(ast.extra[fieldPtrPtr], .Field, .Enum)) {
                    const lexeme = tokens.get(ast.signatures.get(ast.extra[fieldPtrPtr]).name).lexeme(resolver.context, resolver.dataIndex());
                    resolver.report("Given field '{s}' is already present in the enum body.", .{lexeme});
                    return error.DuplicateSymbol;
                }
            }
        },
        .UnionDefinition => {
            const body = try resolver.scopes.addOne(allocator);
            resolver.scopes.set(body, Scope{
                .parent = resolver.currentScope,
                .module = resolver.scopes.items(.module)[resolver.currentScope],
                .kind = .Union,
            });

            const previous = resolver.currentScope;
            defer resolver.currentScope = previous;
            resolver.currentScope = body;

            var offset: u32 = 1;
            const tagged = ast.extra[expr.value] == 1;
            if (tagged) {
                const explicit = ast.extra[expr.value + 1] == 1;
                if (explicit) {
                    const tag = ast.extra[expr.value + 2];
                    try resolver.resolveExpression(tag);
                }

                offset = if (explicit) 3 else 2;
            }

            const defs = defines.Range{
                .start = ast.extra[expr.value + offset + 2],
                .end = ast.extra[expr.value + offset + 3],
            };

            try resolver.handleScopeDefs(defs);

            const fields = defines.Range{
                .start = ast.extra[expr.value + offset],
                .end = ast.extra[expr.value + offset + 1],
            };

            for (fields.start..fields.end) |fieldPtrPtr| {
                if (try resolver.resolveSignature(ast.extra[fieldPtrPtr], .Field, .Union)) {
                    const lexeme = tokens.get(ast.signatures.get(ast.extra[fieldPtrPtr]).name).lexeme(resolver.context, resolver.dataIndex());
                    resolver.report("Given field '{s}' collides with the previous definition of '{s}'.", .{lexeme, lexeme});
                    return error.DuplicateSymbol;
                }
            }
        },
        .FunctionDefinition => {
            const params = defines.Range{
                .start = ast.extra[expr.value],
                .end = ast.extra[expr.value + 1],
            };

            const function = try resolver.scopes.addOne(allocator);
            resolver.scopes.set(function, .{
                .module = resolver.scopes.items(.module)[resolver.currentScope],
                .parent = resolver.currentScope,
                .kind = .Block,
            });

            const previous = resolver.currentScope;
            defer resolver.currentScope = previous;
            resolver.currentScope = function;

            for (params.start..params.end) |paramPtrPtr| {
                const lexeme = tokens.get(ast.signatures.get(ast.extra[paramPtrPtr]).name).lexeme(resolver.context, resolver.dataIndex());
                if (try resolver.resolveSignature(ast.extra[paramPtrPtr], .Parameter, .Block)) {
                    resolver.report("Duplicate parameter name '{s}'.", .{lexeme});
                    return error.DuplicateSymbol;
                }
            }

            const returns = ast.extra[expr.value + 2];
            try resolver.resolveExpression(returns);

            const body = ast.extra[expr.value + 3];
            try resolver.resolveStatement(body, false);
        },
        .Mark => {
            const marks = defines.Range{
                .start = ast.extra[expr.value],
                .end = ast.extra[expr.value + 1],
            };

            for (marks.start..marks.end) |mark| {
                try resolver.resolveExpression(ast.extra[mark]);
            }

            const marked = ast.extra[expr.value + 2];
            try resolver.resolveExpression(marked);
        },
        .Lambda => {
            const captures = defines.Range{
                .start = ast.extra[expr.value],
                .end = ast.extra[expr.value + 1],
            };

            const lambda = try resolver.scopes.addOne(allocator);
            resolver.scopes.set(lambda, .{
                .module = resolver.scopes.items(.module)[resolver.currentScope],
                .parent = resolver.currentScope,
                .kind = .Block,
            });

            const previous = resolver.currentScope;
            defer resolver.currentScope = previous;
            resolver.currentScope = lambda;

            for (captures.start..captures.end) |capturePtrPtr| {
                const name = ast.extra[capturePtrPtr];
                const lexeme = tokens.get(name).lexeme(resolver.context, resolver.dataIndex());

                const decl = try resolver.decls.addOne(allocator);
                resolver.decls.set(decl, .{
                    .kind = .Parameter,
                    .scope = resolver.currentScope,
                    .public = false,
                    .token = name,
                    .node = name,
                    .type = 0,
                    .topLevel = false,
                });

                const isPresent = resolver.lookup.getOrPut(allocator, .{ .name = lexeme, .scope = resolver.currentScope })
                    catch return error.AllocatorFailure;

                if (isPresent.found_existing) {
                    resolver.report("Duplicate capture '{s}'.", .{lexeme});
                    return error.DuplicateSymbol;
                }

                isPresent.value_ptr.* = decl;
            }

            const body = ast.extra[expr.value + 2];
            try resolver.resolveExpression(body);
        },
        .Call => {
            const function = ast.extra[expr.value];
            try resolver.resolveExpression(function);

            const args = ast.extra[expr.value + 1];
            try resolver.resolveExpression(args);
        },
        .Conditional => {
            const condition = ast.extra[expr.value];
            try resolver.resolveExpression(condition);

            const body = ast.extra[expr.value + 1];
            try resolver.resolveExpression(body);

            const elseBody = ast.extra[expr.value + 2];
            try resolver.resolveExpression(elseBody);
        },
        .Switch => {
            const item = ast.extra[expr.value];
            try resolver.resolveExpression(item);

            const cases = defines.Range{
                .start = ast.extra[expr.value + 1],
                .end = ast.extra[expr.value + 2],
            };

            var case: u32 = cases.start;
            while (case < cases.end) : (case += 3) {
                const pattern = ast.extra[case];

                if (pattern != 0) {
                    try resolver.resolveExpression(pattern);
                }

                const caseScope = try resolver.scopes.addOne(allocator);
                resolver.scopes.set(caseScope, .{
                    .module = resolver.scopes.items(.module)[resolver.currentScope],
                    .parent = resolver.currentScope,
                    .kind = .Block,
                });

                const previous = resolver.currentScope;
                defer resolver.currentScope = previous;
                resolver.currentScope = caseScope;

                const capture = ast.extra[case + 1];
                if (capture != 0) {
                    const decl = try resolver.decls.addOne(allocator);
                    resolver.decls.set(decl, .{
                        .scope = resolver.currentScope,
                        .kind = .Capture,
                        .public = false,
                        .token = capture,
                        .node = item,
                        .type = 0,
                        .topLevel = false,
                    });

                    const lexeme = tokens.get(capture).lexeme(resolver.context, resolver.dataIndex());
                    resolver.lookup.put(allocator, .{ .name = lexeme, .scope = resolver.currentScope }, decl)
                        catch return error.AllocatorFailure;
                }

                const body = ast.extra[case + 2];
                try resolver.resolveExpression(body);
            }
        },
        .MutableType, .PointerType, .SliceType, .CPointerType => try resolver.resolveExpression(expr.value),
        .ArrayType => {
            const size = ast.extra[expr.value];
            try resolver.resolveExpression(size);

            const inner = ast.extra[expr.value + 1];
            try resolver.resolveExpression(inner);
        },
        .FunctionType => {
            const args = ast.extra[expr.value];
            try resolver.resolveExpression(args);

            const returns = ast.extra[expr.value + 1];
            try resolver.resolveExpression(returns);
        },
        .Scoping => _ = try resolver.resolveScoping(ast, tokens, exprPtr, false),
        .ExpressionList => {
            const expressions = defines.Range{
                .start = ast.extra[expr.value],
                .end = ast.extra[expr.value + 1],
            };

            for (expressions.start..expressions.end) |expressionPtrPtr| {
                try resolver.resolveExpression(ast.extra[expressionPtrPtr]);
            }
        },
        .Dot => try resolver.resolveExpression(ast.extra[expr.value]),
        else => {},
    }
}

fn resolveScoping(
    resolver: *Resolver,
    ast: *const Parser.AST,
    tokens: *const Lexer.TokenList.Slice,
    expr: defines.ExpressionPtr,
    inside: bool,
) Error!?defines.Offset {
    // TODO: A non-allocating scope resolution function

    const extra: defines.OpaquePtr = ast.expressions.items(.value)[expr];
    
    const lhsPtr = ast.extra[extra];

    const lhs = ast.expressions.get(lhsPtr);
    const leftMost = blk: switch (lhs.type) {
        .Identifier => {
            const left = tokens.get(lhs.value).lexeme(resolver.context, ast.tokens);

            if (try resolver.tryLookName(left)) |found| {
                resolver.resolved.putNoClobber(resolver.arena.allocator(), .{
                    .file = ast.tokens,
                    .expr = lhsPtr,
                }, found) catch return error.AllocatorFailure;
            }

            break :blk @as(defines.Offset, tokens.items(.start)[lhs.value]);
        },
        .Scoping => try resolver.resolveScoping(ast, tokens, lhsPtr, true),
        else => {
            try resolver.resolveExpression(lhsPtr);
            break :blk null;
        },
    };

    if (leftMost) |left| {
        const file = resolver.context.getFile(ast.tokens);

        const rightMost: defines.Offset = tokens.items(.end)[ast.extra[extra + 1]];
        const scoping = file[left..rightMost];

        if (try resolver.tryLookName(scoping)) |decl| {
            resolver.resolved.putNoClobber(resolver.arena.allocator(), .{
                .file = ast.tokens,
                .expr = expr,
            }, decl) catch return error.AllocatorFailure;

            return leftMost;
        }
    }

    if (resolver.resolved.get(.{
        .file = ast.tokens,
        .expr = lhsPtr
    })) |declPtr| blk: {
        const decl = resolver.decls.get(declPtr);

        if (decl.kind != .Namespace) {
            break :blk;
        }

        const member = tokens.get(ast.extra[extra + 1]).lexeme(resolver.context, ast.tokens);

        if (try resolver.tryLookNameAt(member, decl.node)) |foundPtr| {
            resolver.resolved.putNoClobber(resolver.arena.allocator(), .{
                .file = ast.tokens,
                .expr = expr,
            }, foundPtr) catch return error.AllocatorFailure;

            return leftMost;
        }
        else if (!inside) {
            resolver.report("Couldn't find given symbol '{s}' in module '{s}'.", .{
                member,
                resolver.modules.modules.get(resolver.scopes.get(decl.node).module).name
            });
            return error.InvalidIdentifier;
        }
    }

    const moduleName = resolver.getModuleName(lhsPtr);

    if (moduleName[0] == '/') {
        return leftMost;
    }

    if (resolver.modules.ids.contains(moduleName)) {
        resolver.report("Given module '{s}' is not imported into the current scope.", .{
            moduleName,
        });
        return error.ModuleNotInScope;
    }

    return leftMost;
}

fn resolveSignature(resolver: *Resolver, signaturePtr: defines.SignaturePtr, comptime signatureType: Declaration.Kind, comptime bodyType: Scope.Kind) Error!bool {
    const allocator = resolver.arena.allocator();
    const ast = resolver.context.getAST(resolver.dataIndex());
    const tokens = resolver.context.getTokens(resolver.dataIndex());

    switch (signatureType) {
        .Field, .Parameter => |t| {
            if (bodyType == .Enum) {
                if (t != .Field) {
                    @compileError("Illegal signature type.");
                }

                const field = tokens.get(signaturePtr);
                resolver.lastToken = signaturePtr;
                const lexeme = field.lexeme(resolver.context, resolver.dataIndex());

                const isPresent = resolver.lookup.getOrPut(allocator, .{ .name = lexeme, .scope = resolver.currentScope })
                    catch return error.AllocatorFailure;

                return isPresent.found_existing;
            }
            else {
                const field = ast.signatures.get(signaturePtr);
                resolver.lastToken = field.name;
                const lexeme = tokens.get(field.name).lexeme(resolver.context, resolver.dataIndex());

                if (field.type != 0) {
                    try resolver.resolveExpression(field.type);
                }

                const decl = try resolver.decls.addOne(allocator);
                resolver.decls.set(decl, .{
                    .kind = t,
                    .scope = resolver.currentScope,
                    .public = field.public,
                    .token = field.name,
                    .node = field.type,
                    .type = field.type,
                    .topLevel = false,
                });

                const isPresent = resolver.lookup.getOrPut(allocator, .{ .name = lexeme, .scope = resolver.currentScope })
                    catch return error.AllocatorFailure;

                return
                    if (isPresent.found_existing) true
                    else blk: {
                        isPresent.value_ptr.* = decl;
                        break :blk false;
                    };
            }
        },
        else => unreachable,
    }
}

fn prepassScope(resolver: *Resolver, declarations: defines.Range) Error!void {
    const allocator = resolver.arena.allocator();
    const ast = resolver.context.getAST(resolver.dataIndex());
    const tokens = resolver.context.getTokens(resolver.dataIndex());

    for (declarations.start..declarations.end) |declarationPtrPtr| {
        const expr = ast.statements.items(.value)[ast.extra[declarationPtrPtr]];

        const signature = ast.extra[expr];
        
        const field = ast.signatures.items(.name)[signature];
        resolver.lastToken = field;
        const lexeme = tokens.get(field).lexeme(resolver.context, resolver.dataIndex());

        const decl = try resolver.decls.addOne(allocator);
        resolver.decls.set(decl, .{
            .kind = .Variable,
            .scope = resolver.currentScope,
            .public = false,
            .token = field,
            .node = ast.extra[expr + 1],
            .type = ast.signatures.items(.type)[signature],
            .topLevel = true,
        });

        const isPresent = resolver.lookup.getOrPut(allocator, .{ .name = lexeme, .scope = resolver.currentScope })
            catch return error.AllocatorFailure;

        if (isPresent.found_existing) {
            resolver.report("Given definition '{s}' collides with the previous definition of '{s}'.", .{lexeme, lexeme});
            return error.DuplicateSymbol;
        }

        isPresent.value_ptr.* = decl;
    }
}

fn handleScopeDefs(resolver: *Resolver, declarations: defines.Range) Error!void {
    const ast = resolver.context.getAST(resolver.dataIndex());

    try resolver.prepassScope(declarations);

    for (declarations.start..declarations.end) |declPtrPtr| {
        const def = ast.statements.items(.value)[ast.extra[declPtrPtr]];

        const signature = ast.extra[def]; 
        const initializer = ast.extra[def + 1];

        const field = ast.signatures.get(signature);
        resolver.lastToken = field.name;

        if (field.type != 0) {
            try resolver.resolveExpression(field.type);
        }

        const decl = try resolver.look(field.name);
        resolver.decls.set(decl, .{
            .kind = .Variable,
            .scope = resolver.currentScope,
            .public = field.public,
            .token = field.name,
            .node = initializer,
            .type = field.type,
            .topLevel = true,
        });
        

        try resolver.resolveExpression(initializer);
    }
}

fn lookNameAt(resolver: *Resolver, name: []const u8, scope: defines.ScopePtr) Error!defines.DeclPtr {
    const currentModule = resolver.modules.modules.items(.name)[resolver.scopes.items(.module)[scope]];

    var current: ?defines.ScopePtr = scope;
    while (current) |s| {
        if (resolver.lookup.get(.{ .scope = s, .name = name })) |declPtr| {
            const module = resolver.scopes.items(.module)[resolver.decls.items(.scope)[declPtr]];
            const public = resolver.decls.items(.public)[declPtr];

            if (public or module == resolver.scopes.items(.module)[resolver.currentScope]) {
                return declPtr;
            }

            const modulename = resolver.modules.modules.items(.name)[module];
            resolver.report("'{s}::{s}' is inaccessible due to its visibility level.", .{modulename, name});
            return error.AccessSpecifierMismatch;
        }
        current = resolver.scopes.items(.parent)[s];
    }

    resolver.report("Couldn't resolve given identifier '{s}' in the given scope ({s}).", .{
        name,
        currentModule,
    });
    return error.InvalidIdentifier;
}

fn lookAt(resolver: *Resolver, namePtr: defines.TokenPtr, scope: defines.ScopePtr) Error!defines.DeclPtr {
    resolver.lastToken = namePtr;
    const name = resolver.context
        .getTokens(resolver.dataIndex())
        .get(namePtr)
        .lexeme(resolver.context, resolver.dataIndex());
    return resolver.lookNameAt(name, scope);
}

fn tryLookNameAt(resolver: *Resolver, name: []const u8, scope: defines.ScopePtr) Error!?defines.DeclPtr {
    var current: ?defines.ScopePtr = scope;
    while (current) |s| {
        if (resolver.lookup.get(.{ .scope = s, .name = name })) |declPtr| {
            const module = resolver.scopes.items(.module)[resolver.decls.items(.scope)[declPtr]];
            const public = resolver.decls.items(.public)[declPtr];

            if (public or module == resolver.scopes.items(.module)[resolver.currentScope]) {
                return declPtr;
            }

            const modulename = resolver.modules.modules.items(.name)[module];
            resolver.report("'{s}::{s}' is inaccessible due to its visibility level.", .{modulename, name});
            return error.AccessSpecifierMismatch;
        }
        current = resolver.scopes.items(.parent)[s];
    }

    return null;
}

fn tryLookName(resolver: *Resolver, name: []const u8) Error!?defines.DeclPtr {
    return resolver.tryLookNameAt(name, resolver.currentScope);
}

fn lookName(resolver: *Resolver, name: []const u8) Error!defines.DeclPtr {
    return resolver.lookNameAt(name, resolver.currentScope);
}

fn look(resolver: *Resolver, namePtr: defines.TokenPtr) Error!defines.DeclPtr {
    resolver.lastToken = namePtr;
    return resolver.lookAt(namePtr, resolver.currentScope);
}

fn report(resolver: *Resolver, comptime fmt: []const u8, args: anytype) void {
    common.log.err(fmt, args);
    const token = resolver.context.getTokens(resolver.dataIndex()).get(resolver.lastToken);
    const position = token.position(resolver.context, resolver.dataIndex());
    common.log.err(("." ** 4) ++ " In {s} {d}:{d}", .{ resolver.context.getFileName(resolver.dataIndex()), position.line, position.column});
    token.printLocation(resolver.arena.allocator(), resolver.context, resolver.dataIndex(), position, true);
}

fn dataIndex(resolver: *const Resolver) u32 {
    return resolver.modules.modules.items(.dataIndex)[resolver.scopes.items(.module)[resolver.currentScope]];
}

fn getModuleName(resolver: *Resolver, module: defines.ExpressionPtr) []const u8 {
    const ast = resolver.context.getAST(resolver.dataIndex());
    const tokens = resolver.context.getTokens(resolver.dataIndex());

    if (ast.expressions.items(.type)[module] == .Identifier) {
        resolver.lastToken = ast.expressions.items(.value)[module];
        return tokens.get(resolver.lastToken).lexeme(resolver.context, resolver.dataIndex());
    }

    if (ast.expressions.items(.type)[module] != .Scoping) {
        return "/Couldn't Do it/";
    }

    const exprPtr = ast.expressions.items(.value)[module];
    var expr = ast.extra[exprPtr];

    while (ast.expressions.items(.type)[expr] != .Identifier) {
        if (ast.expressions.items(.type)[expr] != .Scoping) {
            return "/Couldn't Do it/";
        }
        expr = ast.extra[ast.expressions.items(.value)[expr]];
    }

    resolver.lastToken = ast.expressions.items(.value)[expr];
    const member = ast.extra[exprPtr + 1];
    const end = tokens.items(.end)[member];
    const start = tokens.items(.start)[resolver.lastToken];

    return resolver.context.getFile(resolver.dataIndex())[start..end];
}

pub const builtins = [_][]const u8 {
    "u32", "i32", "u8", "i8", "bool",
    "float", "void", "type", "noreturn",
    "enum_literal", "comptime_int", "comptime_float",
    "any",

    "undefined", "typeInfo", "hasField", "compileError",
    "bitSizeOf", "unreachable", "enumStr", "typeOf",
    "field", "fieldIndex", "hasDef", "definitionIndex",
    "this", "sizeOf", "comptimeAlloc", "bitSet", "cast",
    "as",
};

pub fn BuiltinIndex(comptime builtin: []const u8) u32 {
    var index: u32 = 0;
    inline for (builtins) |b| {
        defer index += 1;
        if (std.mem.eql(u8, b, builtin)) {
            return index;
        }
    }

    unreachable;
}
