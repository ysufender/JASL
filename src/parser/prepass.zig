const std = @import("std");
const parser = @import("parser.zig");
const common = @import("../core/common.zig");
const types = @import("../core/types.zig");
const arraylist = @import("../util/arraylist.zig");
const lexer = @import("../lexer/lexer.zig");

const Context = common.CompilerContext;
const Error = common.CompilerError;

/// Contains both public and private top level
/// symbols.
pub const Module = struct {
    const Self = @This();

    pub const Symbol = struct {
        name: types.TokenPtr,
        value: types.ExpressionPtr,
    };

    /// namespace of the module
    name: []const u8,

    /// Also file and token list index
    ast: types.ASTPtr,

    symbolPtrs: SymbolMap,
    symbols: SymbolList,
    dependencies: DependencyList,

    pub fn print(self: *const Self, context: *Context) void {
        const ast = context.getAST(self.ast);
        std.debug.print("\n{s} with id {d}:\n", .{self.name, self.ast});
        std.debug.print("\tFile: {s}\n", .{context.getFileName(self.ast)});
        std.debug.print("\n\tAST:\n", .{});
        ast.print(context);
        std.debug.print("\tDependencies:\n", .{});
        for (self.dependencies.items[0..@min(16, self.dependencies.items.len)]) |dependency| {
            std.debug.print("\t\t{s}\n", .{dependency});
        }
        std.debug.print("\tSymbols:\n", .{});
        for (self.symbols.items(.name)[0..@min(16, self.symbols.len)]) |symbol| {
            std.debug.print("\t\tToken ID: {d}\n", .{symbol});
            std.debug.print("\t\t{s}\n", .{context.getTokens(ast.tokens).get(symbol).lexeme(context, self.ast)});
        }
    }

    pub fn dupe(self: *const Self, allocator: std.mem.Allocator) Error!Self {
        return .{
            .name = allocator.dupe(u8, self.name) catch return error.AllocatorFailure,
            .ast = self.ast,
            .symbolPtrs = self.symbolPtrs.clone(allocator) catch return error.AllocatorFailure,
            .symbols = try self.symbols.dupe(allocator),
            .dependencies = self.dependencies.clone(allocator) catch return error.AllocatorFailure,
        };
    }
};

pub const ModuleList = arraylist.MultiArrayList(Module);
pub const SymbolList = arraylist.MultiArrayList(Module.Symbol);
pub const SymbolMap = std.StringHashMapUnmanaged(types.SymbolPtr);
pub const ModuleMap = std.StringHashMapUnmanaged(types.ModulePtr);
pub const DependencyList = std.ArrayList([]const u8);

pub const Prepass = struct {
    const Self = @This();

    initial: parser.AST,
    arena: std.heap.ArenaAllocator,
    safeAlloc: std.heap.ThreadSafeAllocator,

    /// Maps the module names (scoping::expressions::mhm) to ModulePtr's
    moduleMap: ModuleMap,
    modules: ModuleList,
    context: *Context,
    lock: types.Lock,
    hadErr: std.atomic.Value(bool),
    wg: types.WaitGroup,
    pool: types.ThreadPool,

    /// Uses multithreaded allocator under the hood
    pub fn init(context: *Context, initial: types.ASTPtr) Error!Self {
        var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);

        var moduleMap = ModuleMap.empty;
        moduleMap.ensureTotalCapacity(arena.allocator(), 128) catch return error.AllocatorFailure;

        return .{
            .initial = context.getAST(initial),
            .arena = arena,
            .context = context,
            .moduleMap = moduleMap,
            .modules = try ModuleList.init(arena.allocator(), 128),
            .lock = .{},
            .pool = undefined,
            .safeAlloc = undefined,
            .wg = .{},
            .hadErr = .init(false),
        };
    }

    /// Returns a module list slice containing all modules. Releases the ownership.
    pub fn prepass(self: *Self, allocator: std.mem.Allocator) Error!ModuleList.Slice {
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

        // root module AST keeps getting corrupted, hardcode it.
        // self.modules.items(.ast)[self.moduleMap.get("root").?] = 0;

        return try self.modules.slice().dupe(allocator);
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
            .ast = tokens.items(.start)[0],
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
                    const path = getModulePathWithExtension(allocator, statement.value, ast, self.context) catch {
                        self.report("Couldn't get module path.", .{}, file.ast, null);
                        self.hadErr.store(true, .release);
                        fail = true;
                        continue;
                    };

                    if (self.context.isProcessed(path)) {
                        continue;
                    }

                    var scanner = lexer.Scanner.init(allocator, self.context, path) catch {
                        self.report("Couldn't scan module at path {s}.", .{path}, self.context.getFileId(path), null);
                        self.hadErr.store(true, .release);
                        fail = true;
                        continue;
                    };

                    const moduleTokens = scanner.scanAll() catch {
                        self.report("Couldn't scan module at path {s}.", .{path}, file.ast, null);
                        self.hadErr.store(true, .release);
                        fail = true;
                        continue;
                    };

                    var prs = parser.Parser.init(allocator, self.context, moduleTokens) catch {
                        self.report("Couldn't parse module at path {s}.", .{path}, file.ast, null);
                        self.hadErr.store(true, .release);
                        fail = true;
                        continue;
                    };

                    const imported = prs.parse() catch {
                        self.report("Couldn't parse module at path {s}.", .{path}, file.ast, null);
                        self.hadErr.store(true, .release);
                        fail = true;
                        continue;
                    };

                    const module = getModuleName(statement.value, ast, self.context);

                    // ThreadPool already has a mutex.
                    self.pool.spawnWg(&self.wg, prepassImpl, .{self, self.context.getAST(imported), module});

                    file.dependencies.append(allocator, module) catch {
                        self.report("Couldn't add dependency {s} to {s}.", .{module, file.name}, file.ast, null);
                        self.hadErr.store(true, .release);
                        fail = true;
                        continue;
                    };
                },
                .VariableDefinition => {
                    const sigsStart = ast.extra[statement.value];
                    const sigsEnd = ast.extra[statement.value + 1];

                    for (sigsStart..sigsEnd) |ptr| {
                        const sig = ast.signatures.get(ast.extra[@intCast(ptr)]);
                        //if (file.symbols.len <= 16) {
                            //std.debug.print("Sig Start: {d}\n", .{sig.name});
                        //}
                        const sigName = tokens.get(sig.name).lexeme(self.context, file.ast);

                        const idx = file.symbols.addOne(allocator) catch {
                            self.report(
                                "Couldn't add symbol {s} to module map. System is out of memory.",
                                .{sigName},
                                file.ast,
                                sig.name,
                            );
                            self.hadErr.store(true, .release);
                            fail = true;
                            continue :statementLoop;
                        };

                        file.symbolPtrs.put(allocator, sigName, idx) catch {
                            self.report(
                                "Couldn't add symbol {s} to module map. System is out of memory.",
                                .{sigName},
                                file.ast,
                                sig.name,
                            );
                            self.hadErr.store(true, .release);
                            fail = true;
                            continue :statementLoop;
                        };

                        file.symbols.set(idx, .{
                            .name = sig.name,
                            .value = ast.extra[statement.value + 2],
                        });
                    }
                },
                else => { }
            }
        }

        if (fail) {
            return;
        }

        self.lock.lock();
        defer self.lock.unlock();

        const index = self.modules.addOne(allocator) catch {
            self.hadErr.store(true, .release);
            return;
        };
        self.moduleMap.put(allocator, file.name, index) catch {
            self.hadErr.store(true, .release);
            return;
        };
        self.modules.set(index, file);
    }

    fn getModulePathWithExtension(allocator: std.mem.Allocator, id: u32, ast: parser.AST, context: *Context) Error![]const u8 {
        return Context.realpathAlloc(
            allocator,
            std.fmt.allocPrint(allocator, "{s}.jasl", .{
                try getModulePath(allocator, id, ast, context)
            }) catch return error.AllocatorFailure
        );
    }

    /// Returned path is owned by the allocator.
    fn getModulePath(allocator: std.mem.Allocator, id: types.ExpressionPtr, ast: parser.AST, context: *Context) Error![]const u8 {
        const tokens = context.getTokens(ast.tokens);
        const file = tokens.items(.start)[0];

        var parts = arraylist.ReverseStackArray([]const u8, std.fs.max_path_bytes).init();
        var current = id;

        while (true) {
            const expr = ast.expressions.get(current);
            switch (expr.type) {
                .Identifier => {
                    const lexeme = tokens.get(expr.value).lexeme(context, file);
                    parts.append(lexeme) catch return error.PathNameTooLong;
                    break;
                },
                .Scoping => {
                    const lhsExpr = ast.extra[expr.value];
                    const rhsExpr = ast.extra[expr.value + 1];

                    const rhsStr = tokens.get(rhsExpr).lexeme(context, file);
                    parts.append(rhsStr) catch return error.PathNameTooLong;

                    current = lhsExpr;
                },
                else => unreachable,
            }
        }

        return std.fs.path.join(allocator, parts.items) catch error.AllocatorFailure;
    }

    fn getModuleName(id: types.ExpressionPtr, ast: parser.AST, context: *Context) []const u8 {
        const tokens = context.getTokens(ast.tokens);
        const file = tokens.items(.start)[0];
        const expr = ast.expressions.get(id);

        const end = switch (expr.type) {
            .Identifier => tokens.items(.end)[expr.value],
            .Scoping => tokens.items(.end)[ast.extra[expr.value + 1]],
            else => unreachable,
        };
        const start = getModuleNameStartIndex(id, ast, context);

        return context.getFile(file)[start..end];
    }

    fn getModuleNameStartIndex(id: types.ExpressionPtr, ast: parser.AST, context: *Context) u32 {
        const tokens = context.getTokens(ast.tokens);
        var current = id;
        var start = tokens.len;

        while (true) {
            const expr = ast.expressions.get(current);
            switch (expr.type) {
                .Identifier => {
                    start = tokens.items(.start)[expr.value];
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
        const ast = self.context.getAST(file);
        const tokens = self.context.getTokens(ast.tokens);
        
        if (tokens.len > 0) {
            const t_idx = token orelse 0;
            if (t_idx < tokens.len) {
                const position = tokens.get(t_idx).position(self.context, file);
                common.log.err("\t{s} {d}:{d}\n", .{self.context.getFileName(file), position.line, position.column});
                return;
            }
        }
        
        common.log.err("\t{s} (no location available)\n", .{self.context.getFileName(file)});
    }
};
