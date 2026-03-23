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
        std.debug.print("\n{s}:", .{self.name});
        std.debug.print("\n\tFile: {s}", .{context.getFileName(self.ast)});
        std.debug.print("\n\tDependencies:", .{});
        for (self.dependencies.items) |dependency| {
            std.debug.print("\n\t\t{s}", .{dependency});
        }
        std.debug.print("\n\tSymbols:", .{});
        for (self.symbols.items(.name)) |symbol| {
            std.debug.print("\n\t\t{s}", .{context.getAST(self.ast).tokens.get(symbol).lexeme(context, self.ast)});
        }
        std.debug.print("\n", .{});
    }

    pub fn dupe(self: *const Self, allocator: std.mem.Allocator) Error!Self {
        return .{
            .name = allocator.dupe(u8, self.name) catch return error.AllocatorFailure,
            .ast = self.ast,
            .symbolPtrs = try self.symbolPtrs.clone(allocator),
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

    initial: *const parser.AST,
    arena: std.heap.ArenaAllocator,
    safeAlloc: std.heap.ThreadSafeAllocator,

    /// Maps the module names (scoping::expressions::mhm) to ModulePtr's
    moduleMap: ModuleMap,
    modules: ModuleList,
    context: *Context,
    lock: types.Lock,
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
        var hadErr = false;
        self.prepassImpl(self.initial, &hadErr, "root");

        self.wg.wait();

        if (hadErr) {
            return error.ThreadingError;
        }

        return try self.modules.slice().dupe(allocator);
    }

    fn prepassImpl(
        self: *Self,
        ast: *const parser.AST,
        hadErr: *bool,
        name: []const u8,
    ) void {
        const allocator = self.safeAlloc.allocator();

        var file = Module{
            .ast = ast.tokens.items(.start)[0],
            .name = name,
            .dependencies = DependencyList.initCapacity(allocator, 64) catch {
                hadErr.* = true;
                return;
            },
            .symbolPtrs = .empty,
            .symbols = SymbolList.init(allocator, ast.tokens.len / 16) catch {
                hadErr.* = true;
                return;
            },
        };

        file.symbolPtrs.ensureTotalCapacity(allocator, ast.tokens.len / 16) catch {
            hadErr.* = true;
            return;
        };

        statementLoop: for (ast.statementMask) |stmt| {
            const statement = ast.statements.get(stmt);

            switch (statement.type) {
                .Import => {
                    const path = getModulePathWithExtension(allocator, statement.value, ast, self.context) catch {
                        self.report("Couldn't get module path.", .{}, file.ast, null);
                        hadErr.* = true;
                        continue;
                    };

                    if (self.context.isProcessed(path)) {
                        continue;
                    }

                    var scanner = lexer.Scanner.init(allocator, self.context, path) catch {
                        self.report("Couldn't scan module at path {s}.", .{path}, self.context.getFileId(path), null);
                        hadErr.* = true;
                        continue;
                    };

                    const tokens = scanner.scanAll() catch {
                        self.report("Couldn't scan module at path {s}.", .{path}, file.ast, null);
                        hadErr.* = true;
                        continue;
                    };

                    var prs = parser.Parser.init(allocator, self.context, tokens) catch {
                        self.report("Couldn't parse module at path {s}.", .{path}, file.ast, null);
                        hadErr.* = true;
                        continue;
                    };

                    const imported = prs.parse() catch {
                        self.report("Couldn't parse module at path {s}.", .{path}, file.ast, null);
                        hadErr.* = true;
                        continue;
                    };

                    const module = getModuleName(statement.value, ast, self.context);

                    self.lock.lock();
                    var moduleHadErr = false;
                    self.pool.spawnWg(&self.wg, prepassImpl, .{self, self.context.getAST(imported), &moduleHadErr, module});
                    self.lock.unlock();

                    if (moduleHadErr) {
                        self.report("Couldn't prepass module at path {s}.", .{path}, file.ast, null);
                        hadErr.* = true;
                        continue;
                    }

                    file.dependencies.append(allocator, module) catch {
                        self.report("Couldn't add dependency {s} to {s}.", .{module, file.name}, file.ast, null);
                        hadErr.* = true;
                        continue;
                    };
                },
                .VariableDefinition => {
                    const sigsStart = ast.extra[statement.value];
                    const sigsEnd = ast.extra[statement.value + 1];

                    for (sigsStart..sigsEnd) |ptr| {
                        const sig = ast.signatures.get(ast.extra[@intCast(ptr)]);
                        const sigName = ast.tokens.get(sig.name).lexeme(self.context, file.ast);

                        const idx = file.symbols.addOne(allocator) catch {
                            self.report(
                                "Couldn't add symbol {s} to module map. System is out of memory.",
                                .{sigName},
                                file.ast,
                                sig.name,
                            );
                            hadErr.* = true;
                            continue :statementLoop;
                        };

                        file.symbolPtrs.put(allocator, sigName, idx) catch {
                            self.report(
                                "Couldn't add symbol {s} to module map. System is out of memory.",
                                .{sigName},
                                file.ast,
                                sig.name,
                            );
                            hadErr.* = true;
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

        if (hadErr.*) {
            return;
        }

        self.lock.lock();
        defer self.lock.unlock();

        const index = self.modules.addOne(allocator) catch {
            hadErr.* = true;
            return;
        };

        self.modules.set(index, file);
        self.moduleMap.put(allocator, file.name, index) catch {
            hadErr.* = true;
            return;
        };
    }

    fn getModulePathWithExtension(allocator: std.mem.Allocator, id: u32, ast: *const parser.AST, context: *Context) Error![]const u8 {
        return Context.realpathAlloc(
            allocator,
            std.fmt.allocPrint(allocator, "{s}.jasl", .{
                try getModulePath(allocator, id, ast, context)
            }) catch return error.AllocatorFailure
        );
    }

    /// Returned path is owned by the allocator.
    fn getModulePath(allocator: std.mem.Allocator, id: types.ExpressionPtr, ast: *const parser.AST, context: *Context) Error![]const u8 {
        const file = ast.tokens.items(.start)[0];

        var parts = arraylist.ReverseStackArray([]const u8, std.fs.max_path_bytes).init();
        var current = id;

        while (true) {
            const expr = ast.expressions.get(current);
            switch (expr.type) {
                .Identifier => {
                    const lexeme = ast.tokens.get(expr.value).lexeme(context, file);
                    parts.append(lexeme) catch return error.PathNameTooLong;
                    break;
                },
                .Scoping => {
                    const lhsExpr = ast.extra[expr.value];
                    const rhsExpr = ast.extra[expr.value + 1];

                    const rhsStr = ast.tokens.get(rhsExpr).lexeme(context, file);
                    parts.append(rhsStr) catch return error.PathNameTooLong;

                    current = lhsExpr;
                },
                else => unreachable,
            }
        }

        return std.fs.path.join(allocator, parts.items) catch error.AllocatorFailure;
    }

    fn getModuleName(id: types.ExpressionPtr, ast: *const parser.AST, context: *Context) []const u8 {
        const file = ast.tokens.items(.start)[0];
        const expr = ast.expressions.get(id);

        const end = switch (expr.type) {
            .Identifier => ast.tokens.items(.end)[expr.value],
            .Scoping => ast.tokens.items(.end)[ast.extra[expr.value + 1]],
            else => unreachable,
        };
        const start = getModuleNameStartIndex(id, ast);

        return context.getFile(file)[start..end];
    }

    fn getModuleNameStartIndex(id: types.ExpressionPtr, ast: *const parser.AST) u32 {
        var current = id;
        var start = ast.tokens.len;

        while (true) {
            const expr = ast.expressions.get(current);
            switch (expr.type) {
                .Identifier => {
                    start = ast.tokens.items(.start)[expr.value];
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
        self.lock.lock();
        defer self.lock.unlock();

        common.log.err(fmt, args);
        const ast = self.context.getAST(file);
        
        if (ast.tokens.len > 0) {
            const t_idx = token orelse 0;
            if (t_idx < ast.tokens.len) {
                const position = ast.tokens.get(t_idx).position(self.context, file);
                common.log.err("\t{s} {d}:{d}\n", .{self.context.getFileName(file), position.line, position.column});
                return;
            }
        }
        
        common.log.err("\t{s} (Parse failed, no location available)\n", .{self.context.getFileName(file)});
    }
};
