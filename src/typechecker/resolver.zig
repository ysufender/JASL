// TODO: Add Incomplete resolutions for Typechecker to populate.

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
const ResolutionKey = defines.ResolutionKey;

const assert = std.debug.assert;

pub const ScopeList = MultiArrayList(Scope);
pub const DeclarationList = MultiArrayList(Declaration);
pub const ResolutionMap = defines.ResolutionMap(defines.DeclPtr);
const LookupMap = defines.LookupMap([]const u8, defines.DeclPtr);

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
    kind: Kind,
    public: bool,
    index: defines.Offset,
    token: defines.TokenPtr,
    node: defines.StatementPtr,
};

pub const Resolution = struct {
    resolutionMap: ResolutionMap,
    declarations: DeclarationList.Slice,
    lookup: LookupMap,
    scopes: ScopeList.Slice,

    pub fn tryGet(self: *const Resolution, key: ResolutionKey) ?defines.DeclPtr {
        return self.resolutionMap.get(key);
    }

    pub fn get(self: *const Resolution, key: ResolutionKey) defines.DeclPtr {
        return self.tryGet(key).?;
    }

    pub fn tryGetDecl(self: *const Resolution, key: ResolutionKey) ?Declaration {
        return self.declarations.get(self.tryGet(key) orelse return null);
    }

    pub fn getDecl(self: *const Resolution, key: ResolutionKey) Declaration {
        return self.tryGetDecl(self.get(key)).?;
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
            .index = @intCast(i),
            .token = 0,
            .node = 0,
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
                .index = symbol.index,
            });

            lookup.put(allocator, .{
                .scope = scope,
                .name = name,
            }, decl) catch return error.AllocatorFailure;
        }
    }
    
    return .{
        .arena = arena,
        .context = context,
        .scopes = scopes,
        .lookup = lookup,
        .decls = decls,
        .resolved = reso,
        .modules = modules,
        .currentScope = 0,
        .lastToken = 0,
    };
}

pub fn resolve(self: *Resolver, allocator: Allocator) Error!Resolution {
    defer self.arena.deinit();

    var errCount: u32 = 0;
    var lastErr: common.CompilerError = undefined;

    const modules = self.scopes.len;
    for (1..modules) |i| {
        self.currentScope = @intCast(i);
        self.resolveModule() catch |err| {
            errCount += 1;
            lastErr = err;
            if (errCount == self.context.settings.maxErr) {
                common.log.err("Too many errors, aborting compilation.", .{});
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

    return .{
        .resolutionMap = self.resolved.clone(allocator) catch return error.AllocatorFailure,
        .declarations = try collections.deepCopy(self.decls.slice(), allocator),
        .scopes = try collections.deepCopy(self.scopes.slice(), allocator),
        .lookup = self.lookup.clone(allocator) catch return error.AllocatorFailure,
    };
}

fn resolveModule(self: *Resolver) Error!void {
    const module = self.modules.modules.items(.name)[self.scopes.items(.module)[self.currentScope]];

    const kind = self.scopes.items(.kind)[self.currentScope];
    if (kind != .Module) {
        return error.UnexpectedScope;
    }

    var errCount: u32 = 0;
    var lastErr: common.CompilerError = undefined;

    const ast = self.context.getAST(self.dataIndex());
    for (ast.statementMask) |item| {
        self.resolveStatement(item, true) catch |err| {
            errCount += 1;
            lastErr = err;
            common.log.err("Error: {d} <{s}>\n", .{ @intFromError(err), @errorName(err) });
            if (errCount == self.context.settings.maxErr) {
                common.log.err("Too many errors, aborting current module '{s}'.", .{module});
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

fn resolveStatement(self: *Resolver, stmt: defines.StatementPtr, topLevel: bool) Error!void {
    const allocator = self.arena.allocator();
    const ast = self.context.getAST(self.dataIndex());
    const tokens = self.context.getTokens(ast.tokens);

    const statement = ast.statements.get(stmt);
    switch (statement.type) {
        .Block => {
            const stmts = defines.Range{
                .start = ast.extra.items[statement.value],
                .end = ast.extra.items[statement.value + 1]
            };

            const block = try self.scopes.addOne(allocator);
            self.scopes.set(block, .{
                .module = self.scopes.items(.module)[self.currentScope],
                .parent = self.currentScope,
                .kind = .Block,
            });

            const previous = self.currentScope;
            defer self.currentScope = previous;
            self.currentScope = block;

            for (stmts.start..stmts.end) |stmtPtrPtr| {
                const stmtPtr = ast.extra.items[stmtPtrPtr];
                try self.resolveStatement(stmtPtr, false);
            }
        },
        .Conditional => {
            const condition = ast.extra.items[statement.value];
            try self.resolveExpression(condition);

            const body = ast.extra.items[statement.value + 1];
            try self.resolveStatement(body, false);

            const hasElse = ast.extra.items[statement.value + 2] == 1;
            if (hasElse) {
                const elseBody = ast.extra.items[statement.value + 3];
                try self.resolveStatement(elseBody, false);
            }
        },
        .Switch => {
            const item = ast.extra.items[statement.value];
            try self.resolveExpression(item);

            const cases = defines.Range{
                .start = ast.extra.items[statement.value + 1],
                .end = ast.extra.items[statement.value + 2],
            };

            var case: u32 = cases.start;
            while (case < cases.end) : (case += 3) {
                const pattern = ast.extra.items[case];

                if (pattern != 0) {
                    try self.resolveExpression(pattern);
                }

                const caseScope = try self.scopes.addOne(allocator);
                self.scopes.set(caseScope, .{
                    .module = self.scopes.items(.module)[self.currentScope],
                    .parent = self.currentScope,
                    .kind = .Block,
                });

                const previous = self.currentScope;
                defer self.currentScope = previous;
                self.currentScope = previous;

                const capture = ast.extra.items[case + 1];
                if (capture != 0) {
                    const decl = try self.decls.addOne(allocator);
                    self.decls.set(decl, .{
                        .scope = self.currentScope,
                        .kind = .Capture,
                        .public = false,
                        .token = capture,
                        .node = item,
                        .index = 0,
                    });

                    const lexeme = tokens.get(capture).lexeme(self.context, self.dataIndex());
                    self.lookup.put(allocator, .{ .name = lexeme, .scope = self.currentScope }, decl)
                        catch return error.AllocatorFailure;
                }

                const body = ast.extra.items[case + 2];
                try self.resolveStatement(body, false);
            }
        },
        .While => {
            const condition = ast.extra.items[statement.value];
            try self.resolveExpression(condition);

            const body = ast.extra.items[statement.value + 1];
            try self.resolveStatement(body, false);
        },
        .Mark => {
            const marks = defines.Range{
                .start = ast.extra.items[statement.value],
                .end = ast.extra.items[statement.value + 1],
            };

            for (marks.start..marks.end) |mark| {
                try self.resolveExpression(ast.extra.items[mark]);
            }

            const marked = ast.extra.items[statement.value + 2];
            try self.resolveStatement(marked, topLevel);
        },
        .VariableDefinition => {
            const signatures = defines.Range{
                .start = ast.extra.items[statement.value],
                .end = ast.extra.items[statement.value + 1],
            };

            const initializer = ast.extra.items[statement.value + 2];

            try self.resolveExpression(initializer);

            if (topLevel) {
                return;
            }

            for (signatures.start..signatures.end) |signaturePtrPtr| {
                //if (try self.resolveSignature(ast.extra.items[signaturePtrPtr], @as(u32, @intCast(signaturePtrPtr)) - signatures.start, .Variable, .Block)) {
                //    const lexeme = tokens.get(ast.signatures.get(ast.extra.items[signaturePtrPtr]).name).lexeme(self.context, self.dataIndex());
                //    self.report("Given symbol '{s}' collides with the previous definition of '{s}'.", .{lexeme, lexeme});
                //    return error.DuplicateSymbol;
                //}
                const index = @as(u32, @intCast(signaturePtrPtr)) - signatures.start;
                const signature = ast.signatures.get(ast.extra.items[signaturePtrPtr]);
                try self.resolveExpression(signature.type);

                const decl = try self.decls.addOne(allocator);
                self.decls.set(decl, .{
                    .kind = .Variable,
                    .scope = self.currentScope,
                    .public = signature.public,
                    .index = index,
                    .token = signature.name,
                    .node = initializer,
                });

                const name = tokens.get(signature.name).lexeme(self.context, self.dataIndex());
                const isPresent = self.lookup.getOrPut(allocator, .{ .name = name, .scope = self.currentScope })
                    catch return error.AllocatorFailure;

                if (isPresent.found_existing) {
                    self.report("Given symbol '{s}' collides with the previous definition of '{s}'.", .{name, name});
                    return error.DuplicateSymbol;
                }

                isPresent.value_ptr.* = decl;
            }
        },
        .Import => {
            const modulename = self.getModuleName(ast.extra.items[statement.value]);
            const moduleID = self.modules.get(modulename);
            const isAlias = ast.extra.items[statement.value + 1] == 1;
            const alias =
                if (isAlias) ast.extra.items[statement.value + 2]
                else 0;

            const decl = try self.decls.addOne(allocator);
            self.decls.set(decl, .{
                .kind = .Namespace,
                .scope = self.currentScope,
                .public = false,
                .index = 0,
                .token = if (isAlias) alias else ast.extra.items[statement.value + 1],
                .node = moduleID,
            });

            const lexeme =
                if (isAlias) tokens.get(alias).lexeme(self.context, self.dataIndex())
                else modulename;

            const isPresent = self.lookup.getOrPut(allocator, .{ .name = lexeme, .scope = self.currentScope })
                catch return error.AllocatorFailure;

            if (isPresent.found_existing) {
                self.report("Duplicate import of '{s}'.", .{lexeme});
                return error.DuplicateSymbol;
            }

            isPresent.value_ptr.* = decl;
        },

        // Single expr statements
        .Defer, .Return, .Discard, .Expression => try self.resolveExpression(statement.value),

        else => {},
    }
}

fn resolveExpression(self: *Resolver, exprPtr: defines.ExpressionPtr) Error!void {
    const ast = self.context.getAST(self.dataIndex());
    const tokens = self.context.getTokens(self.dataIndex());

    const allocator = self.arena.allocator();

    const expr = ast.expressions.get(exprPtr);
    switch (expr.type) {
        .ValueType, .Identifier => {
            const identifier = expr.value;
            self.lastToken = identifier;

            self.resolved.putNoClobber(allocator, .{ .file = self.dataIndex(), .expr = exprPtr }, try self.look(identifier))
                    catch return error.AllocatorFailure;
        },
        .Indexing, .Assignment => {
            const lhs = ast.extra.items[expr.value];
            try self.resolveExpression(lhs);

            const rhs = ast.extra.items[expr.value + 1];
            try self.resolveExpression(rhs);
        },
        .Slicing => {
            const ptr = ast.extra.items[expr.value];
            try self.resolveExpression(ptr);

            const rangeStart = ast.extra.items[expr.value + 1];
            try self.resolveExpression(rangeStart);

            const rangeEnd = ast.extra.items[expr.value + 2];
            try self.resolveExpression(rangeEnd);
        },
        .Binary => {
            const lhs = ast.extra.items[expr.value];
            try self.resolveExpression(lhs);

            const rhs = ast.extra.items[expr.value + 2];
            try self.resolveExpression(rhs);
        },
        .Unary => {
            const rhs = ast.extra.items[expr.value + 1];
            try self.resolveExpression(rhs);
        },
        .StructDefinition => {
            const body = try self.scopes.addOne(allocator);
            self.scopes.set(body, Scope{
                .parent = self.currentScope,
                .module = self.scopes.items(.module)[self.currentScope],
                .kind = .Struct,
            });

            const previous = self.currentScope;
            defer self.currentScope = previous;
            self.currentScope = body;

            const defs = defines.Range{
                .start = ast.extra.items[expr.value + 2],
                .end = ast.extra.items[expr.value + 3],
            };

            try self.handleScopeDefs(defs);

            const fields = defines.Range{
                .start = ast.extra.items[expr.value],
                .end = ast.extra.items[expr.value + 1],
            };

            for (fields.start..fields.end) |fieldPtrPtr| {
                if (try self.resolveSignature(ast.extra.items[fieldPtrPtr], @as(u32, @intCast(fieldPtrPtr)) - fields.start, .Field, .Struct)) {
                    const lexeme = tokens.get(ast.signatures.get(ast.extra.items[fieldPtrPtr]).name).lexeme(self.context, self.dataIndex());
                    self.report("Given field '{s}' collides with the previous definition of '{s}'.", .{lexeme, lexeme});
                    return error.DuplicateSymbol;
                }
            }
        },
        .EnumDefinition => {
            const body = try self.scopes.addOne(allocator);
            self.scopes.set(body, Scope{
                .parent = self.currentScope,
                .module = self.scopes.items(.module)[self.currentScope],
                .kind = .Enum,
            });

            const previous = self.currentScope;
            defer self.currentScope = previous;
            self.currentScope = body;

            const defs = defines.Range{
                .start = ast.extra.items[expr.value + 2],
                .end = ast.extra.items[expr.value + 3],
            };

            try self.handleScopeDefs(defs);

            const fields = defines.Range{
                .start = ast.extra.items[expr.value],
                .end = ast.extra.items[expr.value + 1],
            };

            for (fields.start..fields.end) |fieldPtrPtr| {
                if (try self.resolveSignature(ast.extra.items[fieldPtrPtr], @as(u32, @intCast(fieldPtrPtr)) - fields.start, .Field, .Enum)) {
                    const lexeme = tokens.get(ast.signatures.get(ast.extra.items[fieldPtrPtr]).name).lexeme(self.context, self.dataIndex());
                    self.report("Given field '{s}' is already present in the enum body.", .{lexeme});
                    return error.DuplicateSymbol;
                }
            }
        },
        .UnionDefinition => {
            const body = try self.scopes.addOne(allocator);
            self.scopes.set(body, Scope{
                .parent = self.currentScope,
                .module = self.scopes.items(.module)[self.currentScope],
                .kind = .Union,
            });

            const previous = self.currentScope;
            defer self.currentScope = previous;
            self.currentScope = body;

            var offset: u32 = 1;
            const tagged = ast.extra.items[expr.value] == 1;
            if (tagged) {
                const explicit = ast.extra.items[expr.value + 1] == 1;
                if (explicit) {
                    const tag = ast.extra.items[expr.value + 2];
                    try self.resolveExpression(tag);
                }

                offset = if (explicit) 3 else 2;
            }

            const defs = defines.Range{
                .start = ast.extra.items[expr.value + offset + 2],
                .end = ast.extra.items[expr.value + offset + 3],
            };

            try self.handleScopeDefs(defs);

            const fields = defines.Range{
                .start = ast.extra.items[expr.value + offset],
                .end = ast.extra.items[expr.value + offset + 1],
            };

            for (fields.start..fields.end) |fieldPtrPtr| {
                if (try self.resolveSignature(ast.extra.items[fieldPtrPtr], @as(u32, @intCast(fieldPtrPtr)) - fields.start, .Field, .Union)) {
                    const lexeme = tokens.get(ast.signatures.get(ast.extra.items[fieldPtrPtr]).name).lexeme(self.context, self.dataIndex());
                    self.report("Given field '{s}' collides with the previous definition of '{s}'.", .{lexeme, lexeme});
                    return error.DuplicateSymbol;
                }
            }
        },
        .FunctionDefinition => {
            const params = defines.Range{
                .start = ast.extra.items[expr.value],
                .end = ast.extra.items[expr.value + 1],
            };

            const function = try self.scopes.addOne(allocator);
            self.scopes.set(function, .{
                .module = self.scopes.items(.module)[self.currentScope],
                .parent = self.currentScope,
                .kind = .Block,
            });

            const previous = self.currentScope;
            defer self.currentScope = previous;
            self.currentScope = function;

            for (params.start..params.end) |paramPtrPtr| {
                const lexeme = tokens.get(ast.signatures.get(ast.extra.items[paramPtrPtr]).name).lexeme(self.context, self.dataIndex());
                if (try self.resolveSignature(ast.extra.items[paramPtrPtr], @as(u32, @intCast(paramPtrPtr)) - params.start, .Parameter, .Block)) {
                    self.report("Duplicate parameter name '{s}'.", .{lexeme});
                    return error.DuplicateSymbol;
                }
            }

            const returns = ast.extra.items[expr.value + 2];
            try self.resolveExpression(returns);

            const body = ast.extra.items[expr.value + 3];
            try self.resolveStatement(body, false);
        },
        .Mark => {
            const marks = defines.Range{
                .start = ast.extra.items[expr.value],
                .end = ast.extra.items[expr.value + 1],
            };

            for (marks.start..marks.end) |mark| {
                try self.resolveExpression(ast.extra.items[mark]);
            }

            const marked = ast.extra.items[expr.value + 2];
            try self.resolveExpression(marked);
        },
        .Lambda => {
            const captures = defines.Range{
                .start = ast.extra.items[expr.value],
                .end = ast.extra.items[expr.value + 1],
            };

            const lambda = try self.scopes.addOne(allocator);
            self.scopes.set(lambda, .{
                .module = self.scopes.items(.module)[self.currentScope],
                .parent = self.currentScope,
                .kind = .Block,
            });

            const previous = self.currentScope;
            defer self.currentScope = previous;
            self.currentScope = lambda;

            for (captures.start..captures.end) |capturePtrPtr| {
                const name = ast.extra.items[capturePtrPtr];
                const lexeme = tokens.get(name).lexeme(self.context, self.dataIndex());

                const decl = try self.decls.addOne(allocator);
                self.decls.set(decl, .{
                    .kind = .Parameter,
                    .scope = self.currentScope,
                    .public = false,
                    .index = @as(u32, @intCast(capturePtrPtr)) - captures.start,
                    .token = name,
                    .node = name,
                });

                const isPresent = self.lookup.getOrPut(allocator, .{ .name = lexeme, .scope = self.currentScope })
                    catch return error.AllocatorFailure;

                if (isPresent.found_existing) {
                    self.report("Duplicate capture '{s}'.", .{lexeme});
                    return error.DuplicateSymbol;
                }

                isPresent.value_ptr.* = decl;
            }
        },
        .Call => {
            const function = ast.extra.items[expr.value];
            try self.resolveExpression(function);

            const args = ast.extra.items[expr.value + 1];
            try self.resolveExpression(args);
        },
        .Conditional => {
            const condition = ast.extra.items[expr.value];
            try self.resolveExpression(condition);

            const body = ast.extra.items[expr.value + 1];
            try self.resolveExpression(body);

            const elseBody = ast.extra.items[expr.value + 2];
            try self.resolveExpression(elseBody);
        },
        .Switch => {
            const item = ast.extra.items[expr.value];
            try self.resolveExpression(item);

            const cases = defines.Range{
                .start = ast.extra.items[expr.value + 1],
                .end = ast.extra.items[expr.value + 2],
            };

            var case: u32 = cases.start;
            while (case < cases.end) : (case += 3) {
                const pattern = ast.extra.items[case];

                if (pattern != 0) {
                    try self.resolveExpression(pattern);
                }

                const caseScope = try self.scopes.addOne(allocator);
                self.scopes.set(caseScope, .{
                    .module = self.scopes.items(.module)[self.currentScope],
                    .parent = self.currentScope,
                    .kind = .Block,
                });

                const previous = self.currentScope;
                defer self.currentScope = previous;
                self.currentScope = previous;

                const capture = ast.extra.items[case + 1];
                if (capture != 0) {
                    const decl = try self.decls.addOne(allocator);
                    self.decls.set(decl, .{
                        .scope = self.currentScope,
                        .kind = .Capture,
                        .public = false,
                        .token = capture,
                        .node = item,
                        .index = 0,
                    });

                    const lexeme = tokens.get(capture).lexeme(self.context, self.dataIndex());
                    self.lookup.put(allocator, .{ .name = lexeme, .scope = self.currentScope }, decl)
                        catch return error.AllocatorFailure;
                }

                const body = ast.extra.items[case + 2];
                try self.resolveExpression(body);
            }
        },
        .Cast => {
            const typeExpr = ast.extra.items[expr.value + 1];
            try self.resolveExpression(typeExpr);

            const lhs = ast.extra.items[expr.value];
            try self.resolveExpression(lhs);
        },
        .MutableType, .PointerType, .SliceType => try self.resolveExpression(expr.value),
        .ArrayType => {
            const size = ast.extra.items[expr.value];
            try self.resolveExpression(size);

            const inner = ast.extra.items[expr.value + 1];
            try self.resolveExpression(inner);
        },
        .FunctionType => {
            const args = ast.extra.items[expr.value];
            try self.resolveExpression(args);

            const returns = ast.extra.items[expr.value + 1];
            try self.resolveExpression(returns);
        },
        .Scoping => {
            var root = exprPtr;
            var chainLen: u32 = 0;
            while (ast.expressions.items(.type)[root] == .Scoping) {
                root = ast.extra.items[ast.expressions.items(.value)[root]];
                chainLen += 1;
            }

            if (ast.expressions.items(.type)[root] != .Identifier) {
                try self.resolveExpression(root);
                return;
            }

            const rootTokenPtr = ast.expressions.items(.value)[root];
            const nameStart = tokens.items(.start)[rootTokenPtr];

            var matchedModuleIdx: ?defines.ModulePtr = null;
            var consumedDepth: u32 = 0;

            var prefixDepth: u32 = 0;
            while (prefixDepth <= chainLen) : (prefixDepth += 1) {
                var cur = exprPtr;
                var steps: u32 = 0;
                while (steps < chainLen - prefixDepth) : (steps += 1) {
                    cur = ast.extra.items[ast.expressions.items(.value)[cur]];
                }

                const endToken =
                    if (prefixDepth == 0) rootTokenPtr
                    else ast.extra.items[ast.expressions.items(.value)[cur] + 1];

                const nameEnd = tokens.items(.end)[endToken];
                const moduleName = self.context.getFile(self.dataIndex())[nameStart..nameEnd];

                if (self.modules.ids.get(moduleName)) |moduleIdx| {
                    matchedModuleIdx = moduleIdx;
                    consumedDepth = prefixDepth;
                }
            }

            var currentDecl: defines.DeclPtr = undefined;

            if (matchedModuleIdx) |moduleIdx| {
                const d = try self.decls.addOne(allocator);
                self.decls.set(d, .{
                    .kind = .Namespace,
                    .scope = self.currentScope,
                    .public = false,
                    .index = 0,
                    .token = rootTokenPtr,
                    .node = moduleIdx,
                });
                currentDecl = d;
            } else {
                currentDecl = self.look(rootTokenPtr) catch return error.InvalidIdentifier;
                consumedDepth = 0;
            }

            var depth: u32 = chainLen - consumedDepth;
            while (depth > 0) {
                depth -= 1;

                var cur = exprPtr;
                var steps: u32 = 0;
                while (steps < depth) {
                    cur = ast.extra.items[ast.expressions.items(.value)[cur]];
                    steps += 1;
                }

                const member = ast.extra.items[ast.expressions.items(.value)[cur] + 1];

                if (self.decls.items(.kind)[currentDecl] == .Namespace) {
                    const targetScope = self.decls.items(.node)[currentDecl];
                    currentDecl = self.lookAt(member, targetScope) catch return;
                } else return;
            }

            self.resolved.putNoClobber(allocator, .{ .file = self.dataIndex(), .expr = exprPtr }, currentDecl)
                catch return error.AllocatorFailure;
        },
        .ExpressionList => {
            const expressions = defines.Range{
                .start = ast.extra.items[expr.value],
                .end = ast.extra.items[expr.value + 1],
            };

            for (expressions.start..expressions.end) |expressionPtrPtr| {
                try self.resolveExpression(ast.extra.items[expressionPtrPtr]);
            }
        },
        .Dot => try self.resolveExpression(ast.extra.items[expr.value]),
        else => {},
    }
}

fn resolveSignature(self: *Resolver, signaturePtr: defines.SignaturePtr, index: defines.Offset, comptime signatureType: Declaration.Kind, comptime bodyType: Scope.Kind) Error!bool {
    const allocator = self.arena.allocator();
    const ast = self.context.getAST(self.dataIndex());
    const tokens = self.context.getTokens(self.dataIndex());


    switch (signatureType) {
        .Field, .Parameter => |t| {
            if (bodyType == .Enum) {
                if (t != .Field) {
                    @compileError("Illegal signature type.");
                }

                const field = tokens.get(signaturePtr);
                self.lastToken = signaturePtr;
                const lexeme = field.lexeme(self.context, self.dataIndex());

                const isPresent = self.lookup.getOrPut(allocator, .{ .name = lexeme, .scope = self.currentScope })
                    catch return error.AllocatorFailure;

                return isPresent.found_existing;
            }
            else {
                const field = ast.signatures.get(signaturePtr);
                self.lastToken = field.name;
                const lexeme = tokens.get(field.name).lexeme(self.context, self.dataIndex());

                if (field.type != 0) {
                    try self.resolveExpression(field.type);
                }

                const decl = try self.decls.addOne(allocator);
                self.decls.set(decl, .{
                    .kind = t,
                    .scope = self.currentScope,
                    .public = field.public,
                    .index = index,
                    .token = field.name,
                    .node = field.type,
                });

                const isPresent = self.lookup.getOrPut(allocator, .{ .name = lexeme, .scope = self.currentScope })
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

fn prepassScope(self: *Resolver, declarations: defines.Range) Error!void {
    const allocator = self.arena.allocator();
    const ast = self.context.getAST(self.dataIndex());
    const tokens = self.context.getTokens(self.dataIndex());

    for (declarations.start..declarations.end) |declarationPtrPtr| {
        const expr = ast.statements.items(.value)[ast.extra.items[declarationPtrPtr]];

        const signatures = defines.Range{
            .start = ast.extra.items[expr],
            .end = ast.extra.items[expr + 1],
        };
        
        for (signatures.start..signatures.end) |signaturePtrPtr| {
            const field = ast.signatures.items(.name)[ast.extra.items[signaturePtrPtr]];
            self.lastToken = field;
            const lexeme = tokens.get(field).lexeme(self.context, self.dataIndex());

            const decl = try self.decls.addOne(allocator);
            self.decls.set(decl, .{
                .kind = .Variable,
                .scope = self.currentScope,
                .public = false,
                .index = 0,
                .token = 0,
                .node = 0,
            });

            const isPresent = self.lookup.getOrPut(allocator, .{ .name = lexeme, .scope = self.currentScope })
                catch return error.AllocatorFailure;

            if (isPresent.found_existing) {
                self.report("Given field '{s}' collides with the previous definition of '{s}'.", .{lexeme, lexeme});
                return error.DuplicateSymbol;
            }

            isPresent.value_ptr.* = decl;
        }
    }
}

fn handleScopeDefs(self: *Resolver, declarations: defines.Range) Error!void {
    const ast = self.context.getAST(self.dataIndex());

    try self.prepassScope(declarations);

    for (declarations.start..declarations.end) |declPtrPtr| {
        const def = ast.statements.items(.value)[ast.extra.items[declPtrPtr]];

        const signatures = defines.Range{
            .start = ast.extra.items[def],
            .end = ast.extra.items[def + 1],
        };
        const initializer = ast.extra.items[def + 2];

        for (signatures.start..signatures.end) |signaturePtrPtr| {
            const signaturePtr = ast.extra.items[signaturePtrPtr];
            const field = ast.signatures.get(signaturePtr);
            self.lastToken = field.name;

            if (field.type != 0) {
                try self.resolveExpression(field.type);
            }

            const decl = try self.look(field.name);
            self.decls.set(decl, .{
                .kind = .Variable,
                .scope = self.currentScope,
                .public = field.public,
                .token = field.name,
                .node = initializer,
                .index = @as(u32, @intCast(signaturePtrPtr)) - signatures.start,
            });
        }

        try self.resolveExpression(initializer);
    }
}

fn lookNameAt(self: *Resolver, name: []const u8, scope: defines.ScopePtr) Error!defines.DeclPtr {
    const currentModule = self.modules.modules.items(.name)[self.scopes.items(.module)[scope]];

    var current: ?defines.ScopePtr = scope;
    while (current) |s| {
        if (self.lookup.get(.{ .scope = s, .name = name })) |declPtr| {
            const module = self.scopes.items(.module)[self.decls.items(.scope)[declPtr]];
            const public = self.decls.items(.public)[declPtr];

            if (public or module == self.scopes.items(.module)[self.currentScope]) {
                return declPtr;
            }

            const modulename = self.modules.modules.items(.name)[module];
            self.report("'{s}::{s}' is inaccessible due to its visibility level.", .{modulename, name});
            return error.InvalidIdentifier;
        }
        current = self.scopes.items(.parent)[s];
    }

    self.report("Couldn't resolve given identifier '{s}' in the given scope ({s}).", .{
        name,
        currentModule,
    });
    return error.InvalidIdentifier;
}

fn lookAt(self: *Resolver, namePtr: defines.TokenPtr, scope: defines.ScopePtr) Error!defines.DeclPtr {
    self.lastToken = namePtr;
    const name = self.context
        .getTokens(self.dataIndex())
        .get(namePtr)
        .lexeme(self.context, self.dataIndex());
    return self.lookNameAt(name, scope);
}

fn lookName(self: *Resolver, name: []const u8) Error!defines.DeclPtr {
    return self.lookNameAt(name, self.currentScope);
}

fn look(self: *Resolver, namePtr: defines.TokenPtr) Error!defines.DeclPtr {
    self.lastToken = namePtr;
    return self.lookAt(namePtr, self.currentScope);
}

fn report(self: *Resolver, comptime fmt: []const u8, args: anytype) void {
    common.log.err(fmt, args);
    const token = self.context.getTokens(self.dataIndex()).get(self.lastToken);
    const position = token.position(self.context, self.dataIndex());
    common.log.err("\t{s} {d}:{d}\n", .{ self.context.getFileName(self.dataIndex()), position.line, position.column});
}

fn dataIndex(self: *const Resolver) u32 {
    return self.modules.modules.items(.dataIndex)[self.scopes.items(.module)[self.currentScope]];
}

fn getModuleName(self: *Resolver, module: defines.ExpressionPtr) []const u8 {
    const ast = self.context.getAST(self.dataIndex());
    const tokens = self.context.getTokens(self.dataIndex());

    if (ast.expressions.items(.type)[module] == .Identifier) {
        self.lastToken = ast.expressions.items(.value)[module];
        return tokens.get(self.lastToken).lexeme(self.context, self.dataIndex());
    }

    const exprPtr = ast.expressions.items(.value)[module];
    var expr = ast.extra.items[exprPtr];

    while (ast.expressions.items(.type)[expr] != .Identifier) {
        expr = ast.extra.items[ast.expressions.items(.value)[expr]];
    }

    self.lastToken = ast.expressions.items(.value)[expr];
    const member = ast.extra.items[exprPtr + 1];
    const end = tokens.items(.end)[member];
    const start = tokens.items(.start)[self.lastToken];

    return self.context.getFile(self.dataIndex())[start..end];
}

const builtins = [_][]const u8 {
    "u32", "i32", "u8", "i8", "bool",
    "float", "void", "type", "any", "noreturn",

    "undefined", "typeInfo", "hasField", "compileError",
    "bitSizeOf", "unreachable", "enumStr", "typeOf",
    "field", "fieldIndex", "hasDef", "definitionIndex",
    "this", "sizeOf", "comptimeAlloc", "bitSet",
};
