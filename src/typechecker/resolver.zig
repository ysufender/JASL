const std = @import("std");
const common = @import("../core/common.zig");
const defines = @import("../core/defines.zig");
const collections = @import("../util/collections.zig");

const Parser = @import("../parser/parser.zig");
const Prepass = @import("../parser/prepass.zig");

const MultiArrayList = collections.MultiArrayList;
const ModuleList = Prepass.ModuleList;
const Error = common.CompilerError;
const Context = common.CompilerContext;
const Allocator = std.mem.Allocator;
const Arena = std.heap.ArenaAllocator;

pub const ScopeList = MultiArrayList(Scope);
pub const DeclarationList = MultiArrayList(Declaration);
pub const LookupMap = std.HashMapUnmanaged(LookupKey, defines.DeclPtr, LookupContext, std.hash_map.default_max_load_percentage);
pub const ResolutionMap = std.AutoHashMapUnmanaged(defines.ExpressionPtr, defines.DeclPtr);

pub const Scope = struct {
    pub const Kind = enum {
        Module,
        Function,
        Block,
        Enum,
        Struct,
        Comptime,
    };

    parent: ?defines.ScopePtr,
    module: defines.ModulePtr,
    kind: Kind,
};

pub const Declaration = struct {
    pub const Kind = enum {
        Variable,
        Parameter,
        Namespace,
        Field,
        Incomplete,
        Builtin,
    };

    scope: defines.ScopePtr,
    kind: Kind,
    public: bool,
    index: defines.Offset,
    token: defines.TokenPtr,
    node: defines.ExpressionPtr,
};

pub const LookupKey = struct {
    scope: defines.ScopePtr,
    name: []const u8,
};

pub const LookupContext = struct {
    pub fn hash(_: LookupContext, key: LookupKey) u64 { 
        var hasher = std.hash.Wyhash.init(0);
        std.hash.autoHashStrat(&hasher, key, .DeepRecursive);
        return hasher.final();
    }

    pub fn eql(_: LookupContext, a: LookupKey, b: LookupKey) bool {
        return
            a.scope == b.scope
            and
            std.mem.eql(u8, a.name, b.name);
    }
};

pub const Resolution = struct {
    resolutionMap: ResolutionMap,
    declarations: DeclarationList.Slice,
    scopes: ScopeList.Slice,

    pub fn tryGet(self: *const Resolution, expr: defines.ExpressionPtr) ?defines.DeclPtr {
        return self.resolutionMap.get(expr);
    }

    pub fn get(self: *const Resolution, expr: defines.ExpressionPtr) defines.DeclPtr {
        return self.resolutionMap.get(expr);
    }

    pub fn getDecl(self: *const Resolution, expr: defines.ExpressionPtr) Declaration {
        return self.declarations.get(self.get(expr));
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

    var scopes = try ScopeList.init(allocator, scopeCap);
    var decls = try DeclarationList.init(allocator, declCap);
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

    for (builtins) |b| {
        const decl = try decls.addOne(allocator);
        decls.set(decl, .{
            .kind = .Builtin,
            .scope = builtin,
            .public = true,
            .index = 0,
            .token = 0,
            .node = 0,
        });

        lookup.putNoClobber(allocator, .{ .name = b, .scope = builtin }, decl)
            catch return error.AllocatorFailure;
    }

    var iterator = modules.modules.iterator();
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

    for (1..self.modules.modules.len) |i| {
        self.currentScope = @intCast(i);
        try self.resolveModule();
    }

    return .{
        .resolutionMap = self.resolved.clone(allocator) catch return error.AllocatorFailure,
        .declarations = try collections.deepCopy(self.decls.slice(), allocator),
        .scopes = try collections.deepCopy(self.scopes.slice(), allocator),
    };
}

fn resolveModule(self: *Resolver) Error!void {
    const kind = self.scopes.items(.kind)[self.currentScope];
    if (kind != .Module) {
        return error.UnexpectedScope;
    }

    const ast = self.context.getAST(self.dataIndex());
    for (ast.statementMask) |item| {
        try self.resolveStatement(item, true);
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
                .start = ast.extra[statement.value],
                .end = ast.extra[statement.value + 1]
            };

            const block = try self.scopes.addOne(allocator);
            const previous = self.currentScope;
            defer self.currentScope = previous;
            self.currentScope = block;

            for (stmts.start..stmts.end) |stmtPtrPtr| {
                const stmtPtr = ast.extra[stmtPtrPtr];
                try self.resolveStatement(stmtPtr, false);
            }
        },
        .Conditional => {
            const condition = ast.extra[statement.value];
            try self.resolveExpression(condition);

            const body = ast.extra[statement.value + 1];
            try self.resolveStatement(body, false);

            const hasElse = ast.extra[statement.value + 2] == 1;
            if (hasElse) {
                const elseBody = ast.extra[statement.value + 3];
                try self.resolveStatement(elseBody, false);
            }
        },
        .Switch => {
            const item = ast.extra[statement.value];
            try self.resolveExpression(item);

            const cases = defines.Range{
                .start = ast.extra[statement.value + 1],
                .end = ast.extra[statement.value + 2],
            };

            var case: u32 = cases.start;
            while (case < cases.end) : (case += 2) {
                const pattern = ast.extra[case];
                const body = ast.extra[case + 1];

                try self.resolveExpression(pattern);
                try self.resolveStatement(body, false);
            }
        },
        .While => {
            const condition = ast.extra[statement.value];
            try self.resolveExpression(condition);

            const body = ast.extra[statement.value + 1];
            try self.resolveStatement(body, false);
        },
        .Mark => {
            const marks = defines.Range{
                .start = ast.extra[statement.value],
                .end = ast.extra[statement.value + 1],
            };

            for (marks.start..marks.end) |mark| {
                try self.resolveExpression(ast.extra[mark]);
            }

            const marked = ast.extra[statement.value + 2];
            try self.resolveStatement(marked, topLevel);
        },
        .VariableDefinition => {
            const signatures = defines.Range{
                .start = ast.extra[statement.value],
                .end = ast.extra[statement.value + 1],
            };

            const initializer = ast.extra[statement.value + 2];

            try self.resolveExpression(initializer);

            if (topLevel) {
                return;
            }

            for (signatures.start..signatures.end) |signaturePtrPtr| {
                const signature = ast.signatures.get(ast.extra[signaturePtrPtr]);
                self.lastToken = signature.name;
                const lexeme = tokens.get(signature.name).lexeme(self.context, self.dataIndex());

                const decl = try self.decls.addOne(allocator);
                self.decls.set(decl, .{
                    .kind = .Variable,
                    .scope = self.currentScope,
                    .public = signature.public,
                    .index = @as(u32, @intCast(signaturePtrPtr)) - signatures.start,
                    .token = signature.name,
                    .node = initializer,
                });

                const isPresent = self.lookup.getOrPut(allocator, .{ .name = lexeme, .scope = self.currentScope })
                    catch return error.AllocatorFailure;

                if (isPresent.found_existing) {
                    const module = self.modules.modules.items(.name)[isPresent.key_ptr.scope];
                    const foundToken = self.decls.items(.token)[isPresent.value_ptr.*];
                    const foundPos = tokens.get(foundToken).position(self.context, self.dataIndex());

                    self.report("Given symbol '{s}' already exists in the current scope ({s} {d}:{d}).", .{
                        lexeme,
                        module,
                        foundPos.line,
                        foundPos.column,
                    });
                    return error.DuplicateSymbol;
                }

                isPresent.value_ptr.* = decl;
            }
        },
        .Import => {
            const modulename = self.getModuleName(ast.extra[statement.value]);
            const moduleID = self.modules.get(modulename);
            const isAlias = ast.extra[statement.value + 1] == 1;
            const alias =
                if (isAlias) ast.extra[statement.value + 2]
                else 0;

            const decl = try self.decls.addOne(allocator);
            self.decls.set(decl, .{
                .kind = .Namespace,
                .scope = self.currentScope,
                .public = false,
                .index = 0,
                .token = if (isAlias) alias else ast.extra[statement.value + 1],
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
    const allocator = self.arena.allocator();
    const ast = self.context.getAST(self.dataIndex());

    const expr = ast.expressions.get(exprPtr);
    switch (expr.type) {
        .Identifier => {
            const identifier = expr.value;
            self.lastToken = identifier;
            self.resolved.putNoClobber(allocator, exprPtr, try self.look(identifier))
                    catch return error.AllocatorFailure;
        },
        .Indexing, .Assignment => {
            const lhs = ast.extra[expr.value];
            try self.resolveExpression(lhs);

            const rhs = ast.extra[expr.value + 1];
            try self.resolveExpression(rhs);
        },
        .Binary => {
            const lhs = ast.extra[expr.value];
            try self.resolveExpression(lhs);

            const rhs = ast.extra[expr.value + 2];
            try self.resolveExpression(rhs);
        },
        else => {},
    }
}

fn lookAt(self: *Resolver, namePtr: defines.TokenPtr, scope: defines.ScopePtr) Error!defines.DeclPtr {
    const name = self.context
        .getTokens(self.dataIndex())
        .get(namePtr)
        .lexeme(self.context, self.dataIndex());

    var current: ?defines.ScopePtr = scope;
    while (current) |s| {
        if (self.lookup.get(.{ .scope = s, .name = name })) |declPtr| {
            const module = self.scopes.items(.module)[self.decls.items(.scope)[declPtr]];
            const public = self.decls.items(.public)[declPtr];

            if (public or module == self.scopes.items(.module)[self.currentScope]) {
                return declPtr;
            }
        }
        current = self.scopes.items(.parent)[s];
    }

    self.lastToken = namePtr;

    const module = self.modules.modules.items(.name)[self.scopes.items(.module)[self.currentScope]];
    const position = self.context
        .getTokens(self.dataIndex())
        .get(namePtr)
        .position(self.context, self.dataIndex());

    self.report("Couldn't resolve given identifier '{s}' in the given scope ({s} {d}:{d}).", .{
        name,
        module,
        position.line,
        position.column,
    });
    return error.InvalidIdentifier;
}

fn look(self: *Resolver, namePtr: defines.TokenPtr) Error!defines.DeclPtr {
    return self.lookAt(namePtr, self.currentScope);
}

fn report(self: *Resolver, comptime fmt: []const u8, args: anytype) void {
    common.log.err(fmt, args);
    const token = self.context.getTokens(self.dataIndex()).get(self.lastToken);
    const position = token.position(self.context, self.dataIndex());
    common.log.err("\t{s} {d}:{d}", .{ self.context.getFileName(self.dataIndex()), position.line, position.column});
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
    var expr = ast.extra[exprPtr];

    while (ast.expressions.items(.type)[expr] != .Identifier) {
        expr = ast.extra[ast.expressions.items(.value)[expr]];
    }

    self.lastToken = ast.expressions.items(.value)[expr];
    const member = ast.extra[exprPtr + 1];
    const end = tokens.items(.end)[member];
    const start = tokens.items(.start)[self.lastToken];

    return self.context.getFile(self.dataIndex())[start..end];
}

const builtins: [10][]const u8 = .{
    "u8", "i8", "float", "u32", "i32",
    "bool", "void", "any", "type", "undefined",
};
