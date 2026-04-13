const std = @import("std");
const common = @import("../core/common.zig");
const defines = @import("../core/defines.zig");
const collections = @import("../util/collections.zig");
const threading = @import("../util/threading.zig");

const Lexer = @import("../lexer/lexer.zig");
const Parser = @import("parser.zig");

const Context = common.CompilerContext;
const Error = common.CompilerError;

/// Contains both public and private top level
/// symbols.
pub const Module = struct {
    pub const Symbol = struct {
        public: bool,
        name: defines.TokenPtr,
        value: defines.ExpressionPtr,
        index: u32,
    };

    /// namespace of the module
    name: []const u8,

    /// Also file and token list index
    dataIndex: defines.Offset,

    symbolPtrs: SymbolMap,
    symbols: SymbolList,
    dependencies: DependencyList,

    pub fn print(self: *const Module, context: *Context) void {
        const ast = context.getAST(self.dataIndex);
        std.debug.print("\nModule {s}:\n", .{self.name});
        std.debug.print("\tFile: {s}\n", .{context.getFileName(self.dataIndex)});
        std.debug.print("\tAST:\n", .{});
        ast.print(context);
        std.debug.print("\tDependencies:\n", .{});
        for (self.dependencies.items[0..@min(16, self.dependencies.items.len)]) |dependency| {
            std.debug.print("\t\t{s}\n", .{dependency});
        }
        std.debug.print("\tSymbols:\n", .{});
        for (self.symbols.items(.name), 0..) |symbol, i| {
            std.debug.print("\t\t{s}{s}\n", .{
                if (self.symbols.items(.public)[i]) "pub " else "",
                context.getTokens(ast.tokens).get(symbol).lexeme(context, self.dataIndex)
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

    pub fn get(self: *const ModuleList, name: []const u8) defines.ModulePtr {
        return self.ids.get(name).?;
    }

    pub fn dupe(self: *const ModuleList, allocator: std.mem.Allocator) Error!ModuleList {
        return .{
            .modules = try collections.deepCopy(self.modules.mutableSlice(), allocator),
            .ids= try collections.deepCopy(self.ids, allocator),
        };
    }
};

pub const SymbolList = collections.MultiArrayList(Module.Symbol);
pub const SymbolMap = std.StringHashMapUnmanaged(defines.SymbolPtr);
pub const ModuleMap = std.StringHashMapUnmanaged(defines.ModulePtr);
pub const DependencyList = std.ArrayList([]const u8);

const Prepass = @This();

initial: Parser.AST,
arena: std.heap.ArenaAllocator,
safeAlloc: threading.OnlyIfThreading(std.heap.ThreadSafeAllocator) = undefined,

/// Maps the module names (scoping::expressions::mhm) to ModulePtr's
modules: ModuleList,
context: *Context,
lock: threading.OnlyIfThreading(defines.Lock) = undefined,
hadErr: threading.OnlyIfThreading(std.atomic.Value(bool)) = undefined,
wg: threading.OnlyIfThreading(defines.WaitGroup) = undefined,
pool: threading.OnlyIfThreading(defines.ThreadPool) = undefined,

/// Uses multithreaded allocator under the hood
pub fn init(context: *Context, initial: defines.ASTPtr, allocator: std.mem.Allocator) Error!Prepass {
    var arena = std.heap.ArenaAllocator.init(
        if (defines.threading) std.heap.smp_allocator
        else allocator
    );

    return
        if (defines.threading) .{
            .initial = context.getAST(initial),
            .context = context,
            .modules = try ModuleList.init(arena.allocator(), 128),
            .lock = .{},
            .wg = .{},
            .hadErr = .init(false),
            .arena = arena,
        }
        else .{
            .initial = context.getAST(initial),
            .context = context,
            .modules = try ModuleList.init(arena.allocator(), 128),
            .arena = arena,
        };
}

/// Returns a module list slice containing all modules. Releases the ownership.
pub fn prepass(self: *Prepass, allocator: std.mem.Allocator) Error!ModuleList {
    if (defines.threading) {
        self.safeAlloc = .{
            .child_allocator = self.arena.allocator(),
        };

        self.pool.init(.{
            .allocator = self.safeAlloc.allocator(),
        }) catch return error.ThreadingError;
    }

    defer self.arena.deinit();

    const bname: []const u8 = "builtin";
    const builtin = try self.modules.modules.addOne(allocator);
    self.modules.modules.set(builtin, .{
        .name = try collections.deepCopy(bname, allocator), 
        .dataIndex = 0,
        .dependencies = .empty,
        .symbolPtrs = .empty,
        .symbols = try .init(allocator, 0),
    });
    self.modules.ids.putAssumeCapacityNoClobber(bname, builtin);

    if (defines.threading) {
        self.prepassImpl(self.initial, "root");
    }
    else {
        try self.prepassImpl(self.initial, "root");
    }

    if (defines.threading) {
        self.wg.wait();

        if (self.hadErr.load(.acquire)) {
            return error.ThreadingError;
        }
    }

    for (1..self.modules.modules.len) |i| {
        self.modules.modules.items(.dependencies)[i].shrinkAndFree(
            if (defines.threading) self.safeAlloc.allocator() else self.arena.allocator(),
            self.modules.modules.items(.dependencies)[i].items.len
        );
    }

    return collections.deepCopy(self.modules, allocator);
}

/// Threaded recursive prepassing. Uses mutexes.
fn prepassImpl(self: *Prepass, ast: Parser.AST, name: []const u8) if (defines.threading) void else Error!void {
    const tokens = self.context.getTokens(ast.tokens);
    const allocator =
        if (defines.threading) self.safeAlloc.allocator()
        else self.arena.allocator();

    var file = Module{
        .dataIndex = tokens.items(.start)[0],
        .name = name,
        .dependencies = DependencyList.initCapacity(allocator, @max(tokens.len / 32, 16)) catch |e|
            if (defines.threading) {
                self.hadErr.store(true, .release);
                return;
            }
            else return e,
        .symbolPtrs = .empty,
        .symbols = SymbolList.init(allocator, @max(tokens.len / 16, 16)) catch |e|
            if (defines.threading) {
                self.hadErr.store(true, .release);
                return;
            }
            else return e,
    };

    file.symbolPtrs.ensureTotalCapacity(allocator, @max(tokens.len / 16, 16)) catch |e|
        if (defines.threading) {
            self.hadErr.store(true, .release);
            return;
        }
        else return e;

    var fail = false;

    //std.debug.print("\nPrepass {s}", .{name});
    //ast.print(self.context);
    var statement: Parser.Statement = undefined;
    var first = true;
    var stmt: u32 = 0;
    statementLoop: while (stmt < ast.statementMask.len) {
        if (first) {
            first = false;
            statement = ast.statements.get(ast.statementMask[stmt]);
        }

        case: switch (statement.type) {
            .Import => {
                const module = getModuleName(statement.value, ast, self.context);
                file.dependencies.append(allocator, module) catch {
                    self.report("Couldn't add dependency {s} to {s}.", .{module, file.name}, file.dataIndex, null);

                    fail = true;
                    break :case;
                };

                const path = getModulePathWithExtension(allocator, statement.value, ast, self.context) catch |err| {
                    self.report("Couldn't get module path for {s}: {s}.", .{module, @errorName(err)}, file.dataIndex, null);

                    fail = true;
                    break :case;
                };

                if (self.context.isProcessed(path)) {
                break :case;
                }

                var lexer = Lexer.init(allocator, self.context, path) catch {
                    self.report("Couldn't scan module at path {s}.", .{path}, self.context.getFileId(path), null);

                    fail = true;
                    break :case;
                };

                const moduleTokens = lexer.lex() catch {
                    self.report("Couldn't scan module at path {s}.", .{path}, file.dataIndex, null);

                    fail = true;
                    break :case;
                };

                var prs = Parser.init(allocator, self.context, moduleTokens) catch {
                    self.report("Couldn't parse module at path {s}.", .{path}, file.dataIndex, null);

                    fail = true;
                    break :case;
                };

                const imported = prs.parse() catch {
                    self.report("Couldn't parse module at path {s}.", .{path}, file.dataIndex, null);

                    fail = true;
                    break :case;
                };

                if (defines.threading) {
                    // ThreadPool already has a mutex.
                    self.pool.spawnWg(&self.wg, prepassImpl, .{self, self.context.getAST(imported), module});
                }
                else {
                    try self.prepassImpl(self.context.getAST(imported), module);
                }
            },
            .VariableDefinition => {
                const sigsStart = ast.extra[statement.value];
                const sigsEnd = ast.extra[statement.value + 1];

                for (sigsStart..sigsEnd) |ptr| {
                    const sig = ast.signatures.get(ast.extra[@intCast(ptr)]);
                    const sigName = tokens.get(sig.name).lexeme(self.context, file.dataIndex);

                    const idx = file.symbols.addOne(allocator) catch {
                        self.report(
                            "Couldn't add symbol {s} to module map. System is out of memory.",
                            .{sigName},
                            file.dataIndex,
                            sig.name,
                        );
                        fail = true;
                        break :case;
                    };

                    file.symbolPtrs.put(allocator, sigName, idx) catch {
                        self.report(
                            "Couldn't add symbol {s} to module map. System is out of memory.",
                            .{sigName},
                            file.dataIndex,
                            sig.name,
                        );
                        fail = true;
                        break :case;
                    };

                    file.symbols.set(idx, .{
                        .public = sig.public,
                        .name = sig.name,
                        .value = ast.extra[statement.value + 2],
                        .index = @as(u32, @intCast(ptr)) - sigsStart,
                    });
                }
            },
            .Mark => {
                statement = ast.statements.get(ast.extra[statement.value + 2]); 
                continue :statementLoop;
            },
            else => {
                self.report(
                    "Only definitions are allowed at top-level. Received: {s}",
                    .{@tagName(statement.type)},
                    file.dataIndex,
                    null
                );
                fail = true;
                break :case;
            },
        }

        stmt += 1;
        statement = if (stmt >= ast.statementMask.len) statement else ast.statements.get(ast.statementMask[stmt]);
    }

    if (defines.threading) {
        if (fail) {
            self.hadErr.store(true, .release);
            return;
        }

        self.lock.lock();
        defer self.lock.unlock();
    }
    else {
        if (fail) {
            return error.MultipleErrors;
        }
    }

    const index = self.modules.modules.addOne(allocator) catch |e| {
        if (defines.threading) {
            self.hadErr.store(true, .release);
            return;
        }
        else {
            return e;
        }
    };

    self.modules.ids.put(allocator, file.name, index) catch |e| {
        if (defines.threading) {
            self.hadErr.store(true, .release);
            return;
        }
        else {
            return e;
        }
    };
    self.modules.modules.set(index, file);

    if (self.modules.ids.count() > defines.rehashLimit) {
        self.modules.ids.rehash(std.hash_map.StringContext{});
    }

    self.context.registerModule(&file);
}

fn getModulePathWithExtension(allocator: std.mem.Allocator, id: u32, ast: Parser.AST, context: *Context) Error![]const u8 {
    return context.realpath(
        std.fmt.allocPrint(allocator, "{s}.jasl", .{
            try getModulePath(allocator, id, ast, context)
        }) catch return error.AllocatorFailure
    );
}

/// Returned path is owned by the allocator.
fn getModulePath(allocator: std.mem.Allocator, id: defines.ExpressionPtr, ast: Parser.AST, context: *Context) Error![]const u8 {
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

fn getModuleName(id: defines.ExpressionPtr, ast: Parser.AST, context: *Context) []const u8 {
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

fn getModuleNameStartIndex(id: defines.ExpressionPtr, ast: Parser.AST, context: *Context) u32 {
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

fn report(self: *Prepass, comptime fmt: []const u8, args: anytype, file: u32, token: ?u32) void {
    if (defines.threading) {
        self.lock.lockShared();
        defer self.lock.unlockShared();
    }

    common.log.err(fmt, args);
    if (
        self.context.astMap.items.len > file
        and self.context.getTokens(self.context.getAST(file).tokens).len > 0
    ) {
        const t_idx = token orelse 0;
        if (t_idx < self.context.getTokens(self.context.getAST(file).tokens).len) {
            const position = self.context.getTokens(self.context.getAST(file).tokens).get(t_idx).position(self.context, file);
            common.log.err("\t{s} {d}:{d}\n", .{self.context.getFileName(file), position.line, position.column});
            return;
        }
    }
    
    common.log.err("\t{s} (no location available)\n", .{self.context.getFileName(file)});
}
