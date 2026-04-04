const std = @import("std");
const parser = @import("parser.zig");
const common = @import("../core/common.zig");
const defines = @import("../core/defines.zig");
const collections = @import("../util/collections.zig");
const lexer = @import("../lexer/lexer.zig");

const Context = common.CompilerContext;
const Error = common.CompilerError;

/// Contains both public and private top level
/// symbols.
pub const Module = struct {
    const Self = @This();

    pub const Symbol = struct {
        public: bool,
        name: defines.TokenPtr,
        value: defines.ExpressionPtr,
    };

    /// namespace of the module
    name: []const u8,

    /// Also file and token list index
    dataIndex: defines.Offset,

    symbolPtrs: SymbolMap,
    symbols: SymbolList,
    dependencies: DependencyList,

    pub fn print(self: *const Self, context: *Context) void {
        const ast = context.getAST(self.dataIndex);
        std.debug.print("\nModule {s}:\n", .{self.name});
        std.debug.print("\tFile: {s}\n", .{context.getFileName(self.dataIndex)});
        std.debug.print("\tAST:\n", .{});
        context.getAST(self.dataIndex).print(context);
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
    const Self = @This();
    pub const List = collections.MultiArrayList(Module);
    pub const Map = std.StringHashMapUnmanaged(u32);

    modules: List,
    ids: Map,

    pub fn init(allocator: std.mem.Allocator, cap: u32) Error!Self {
        var ids = Map.empty;

        ids.ensureTotalCapacity(allocator, cap) catch return error.AllocatorFailure;

        return .{
            .modules = try List.init(allocator, cap),
            .ids = ids,
        };
    }

    pub fn dupe(self: *const Self, allocator: std.mem.Allocator) Error!Self {
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

pub const Prepass = struct {
    const Self = @This();

    initial: parser.AST,
    arena: std.heap.ArenaAllocator,
    safeAlloc: std.heap.ThreadSafeAllocator,

    /// Maps the module names (scoping::expressions::mhm) to ModulePtr's
    modules: ModuleList,
    context: *Context,
    lock: defines.Lock,
    hadErr: std.atomic.Value(bool),
    wg: defines.WaitGroup,
    pool: defines.ThreadPool,

    /// Uses multithreaded allocator under the hood
    pub fn init(context: *Context, initial: defines.ASTPtr) Error!Self {
        var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);

        return .{
            .initial = context.getAST(initial),
            .arena = arena,
            .context = context,
            .modules = try ModuleList.init(arena.allocator(), 128),
            .lock = .{},
            .pool = undefined,
            .safeAlloc = undefined,
            .wg = .{},
            .hadErr = .init(false),
        };
    }

    /// Returns a module list slice containing all modules. Releases the ownership.
    pub fn prepass(self: *Self, allocator: std.mem.Allocator) Error!ModuleList {
        self.safeAlloc = .{
            .child_allocator = self.arena.allocator(),
        };

        self.pool.init(.{
            .allocator = self.safeAlloc.allocator(),
        }) catch return error.ThreadingError;

        defer self.arena.deinit();
        self.prepassImpl(self.initial, "root");

        self.wg.wait();

        if (self.hadErr.load(.acquire)) {
            return error.ThreadingError;
        }

        for (0..self.modules.modules.len) |i| {
            self.modules.modules.items(.dependencies)[i].shrinkAndFree(self.safeAlloc.allocator(), self.modules.modules.items(.dependencies)[i].items.len);
        }

        return collections.deepCopy(self.modules, allocator);
    }

    /// Threaded recursive prepassing. Uses mutexes.
    fn prepassImpl(
        self: *Self,
        ast: parser.AST,
        name: []const u8,
    ) void {
        const tokens = self.context.getTokens(ast.tokens);
        //std.debug.print("Prepassing module {s} with id {d}\n", .{name, tokens.items(.start)[0]});
        const allocator = self.safeAlloc.allocator();

        var file = Module{
            .dataIndex = tokens.items(.start)[0],
            .name = name,
            .dependencies = DependencyList.initCapacity(allocator, @max(tokens.len / 32, 16)) catch {
                self.hadErr.store(true, .release);
                return;
            },
            .symbolPtrs = .empty,
            .symbols = SymbolList.init(allocator, @max(tokens.len / 16, 16)) catch {
                self.hadErr.store(true, .release);
                return;
            },
        };

        file.symbolPtrs.ensureTotalCapacity(allocator, @max(tokens.len / 16, 16)) catch {
            self.hadErr.store(true, .release);
            return;
        };

        var fail = false;

        //std.debug.print("\nPrepass {s}", .{name});
        //ast.print(self.context);
        statementLoop: for (ast.statementMask) |stmt| {
            const statement = ast.statements.get(stmt);

            switch (statement.type) {
                .Import => {
                    const module = getModuleName(statement.value, ast, self.context);
                    file.dependencies.append(allocator, module) catch {
                        self.report("Couldn't add dependency {s} to {s}.", .{module, file.name}, file.dataIndex, null);
                        fail = true;
                        continue;
                    };

                    const path = getModulePathWithExtension(allocator, statement.value, ast, self.context) catch |err| {
                        self.report("Couldn't get module path for {s}: {s}.", .{module, @errorName(err)}, file.dataIndex, null);
                        fail = true;
                        continue;
                    };

                    if (self.context.isProcessed(path)) {
                        continue;
                    }

                    var scanner = lexer.Scanner.init(allocator, self.context, path) catch {
                        self.report("Couldn't scan module at path {s}.", .{path}, self.context.getFileId(path), null);
                        fail = true;
                        continue;
                    };

                    const moduleTokens = scanner.scanAll() catch {
                        self.report("Couldn't scan module at path {s}.", .{path}, file.dataIndex, null);
                        fail = true;
                        continue;
                    };

                    var prs = parser.Parser.init(allocator, self.context, moduleTokens) catch {
                        self.report("Couldn't parse module at path {s}.", .{path}, file.dataIndex, null);
                        fail = true;
                        continue;
                    };

                    const imported = prs.parse() catch {
                        self.report("Couldn't parse module at path {s}.", .{path}, file.dataIndex, null);
                        fail = true;
                        continue;
                    };

                    // ThreadPool already has a mutex.
                    self.pool.spawnWg(&self.wg, prepassImpl, .{self, self.context.getAST(imported), module});
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
                            continue :statementLoop;
                        };

                        file.symbolPtrs.put(allocator, sigName, idx) catch {
                            self.report(
                                "Couldn't add symbol {s} to module map. System is out of memory.",
                                .{sigName},
                                file.dataIndex,
                                sig.name,
                            );
                            fail = true;
                            continue :statementLoop;
                        };

                        file.symbols.set(idx, .{
                            .public = sig.public,
                            .name = sig.name,
                            .value = ast.extra[statement.value + 2],
                        });
                    }
                },
                .Extern => {
                    const sign = ast.signatures.items(.name)[ast.extra[statement.value + 2]];
                    const signame = tokens.get(sign).lexeme(self.context, file.dataIndex);

                    const idx = file.symbols.addOne(allocator) catch {
                        self.report(
                            "Couldn't add symbol {s} to module map. System is out of memory.",
                            .{signame},
                            file.dataIndex,
                            sign,
                        );
                        fail = true;
                        continue :statementLoop;
                    };

                    file.symbolPtrs.put(allocator, signame, idx) catch {
                        self.report(
                            "Couldn't add symbol {s} to module map. System is out of memory.",
                            .{signame},
                            file.dataIndex,
                            sign,
                        );
                        fail = true;
                        continue :statementLoop;
                    };

                    file.symbols.set(idx, .{
                        .public = ast.signatures.items(.public)[ast.extra[statement.value + 2]],
                        .name = sign,
                        .value = 0,
                    });
                },
                else => {
                    self.report(
                        "Only definitions are allowed at top-level.",
                        .{},
                        file.dataIndex,
                        null
                    );
                    fail = true;
                    continue :statementLoop;
                },
            }
        }

        if (fail) {
            self.hadErr.store(true, .release);
            return;
        }

        self.lock.lock();
        defer self.lock.unlock();

        const index = self.modules.modules.addOne(allocator) catch {
            self.hadErr.store(true, .release);
            return;
        };
        self.modules.ids.put(allocator, file.name, index) catch {
            self.hadErr.store(true, .release);
            return;
        };
        self.modules.modules.set(index, file);

        if (self.modules.ids.count() > defines.rehashLimit) {
            self.modules.ids.rehash(std.hash_map.StringContext{});
        }
    }

    fn getModulePathWithExtension(allocator: std.mem.Allocator, id: u32, ast: parser.AST, context: *Context) Error![]const u8 {
        return context.realpath(
            std.fmt.allocPrint(allocator, "{s}.jasl", .{
                try getModulePath(allocator, id, ast, context)
            }) catch return error.AllocatorFailure
        );
    }

    /// Returned path is owned by the allocator.
    fn getModulePath(allocator: std.mem.Allocator, id: defines.ExpressionPtr, ast: parser.AST, context: *Context) Error![]const u8 {
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

    fn getModuleName(id: defines.ExpressionPtr, ast: parser.AST, context: *Context) []const u8 {
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

    fn getModuleNameStartIndex(id: defines.ExpressionPtr, ast: parser.AST, context: *Context) u32 {
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

    fn report(self: *Self, comptime fmt: []const u8, args: anytype, file: u32, token: ?u32) void {
        self.lock.lockShared();
        defer self.lock.unlockShared();

        common.log.err(fmt, args);
        if (self.context.getTokens(self.context.getAST(file).tokens).len > 0) {
            const t_idx = token orelse 0;
            if (t_idx < self.context.getTokens(self.context.getAST(file).tokens).len) {
                const position = self.context.getTokens(self.context.getAST(file).tokens).get(t_idx).position(self.context, file);
                common.log.err("\t{s} {d}:{d}\n", .{self.context.getFileName(file), position.line, position.column});
                return;
            }
        }
        
        common.log.err("\t{s} (no location available)\n", .{self.context.getFileName(file)});
    }
};
