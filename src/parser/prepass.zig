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

    /// Maps the module names (scoping::expressions::mhm) to ModulePtr's
    moduleMap: ModuleMap,
    modules: ModuleList,
    context: *Context,
    lock: types.Lock,
    wg: types.WaitGroup,
    pool: types.ThreadPool,
    hadErr: std.atomic.Value(bool),

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
            .wg = .{},
            .hadErr = std.atomic.Value(bool).init(false),
        };
    }

    /// Returns a module list slice containing all modules. Releases the ownership.
    pub fn prepass(self: *Self, allocator: std.mem.Allocator) Error!ModuleList.Slice {
        self.pool.init(.{
            .allocator = self.arena.allocator(),
        }) catch return error.ThreadingError;

        defer self.arena.deinit();
        self.prepassImpl(self.initial, "root");

        self.wg.wait();

        if (self.hadErr.load(.acquire)) {
            return error.ThreadingError;
        }

        return self.modules.toOwnedSlice().dupe(allocator);
    }

    fn prepassImpl(
        self: *Self,
        ast: *const parser.AST,
        name: []const u8,
    ) void {
        var file = Module{
            .ast = ast.tokens.items(.start)[0],
            .name = name,
            .dependencies = DependencyList.initCapacity(self.arena.allocator(), 64) catch {
                self.hadErr.store(true, .release);
                return;
            },
            .symbolPtrs = .empty,
            .symbols = SymbolList.init(self.arena.allocator(), ast.tokens.len / 16) catch {
                self.hadErr.store(true, .release);
                return;
            },
        };

        file.symbolPtrs.ensureTotalCapacity(self.arena.allocator(), ast.tokens.len / 16) catch {
            self.hadErr.store(true, .release);
            return;
        };

        for (ast.statementMask) |stmt| {
            const statement = ast.statements.get(stmt);

            switch (statement.type) {
                .Import => {
                    const path = getModulePathWithExtension(self.arena.allocator(), statement.value, ast, self.context) catch {
                        self.hadErr.store(true, .release);
                        continue;
                    };

                    if (self.context.isProcessed(path)) {
                        continue;
                    }

                    var scanner = lexer.Scanner.init(self.arena.allocator(), self.context, path) catch {
                        self.hadErr.store(true, .release);
                        continue;
                    };

                    const tokens = scanner.scanAll() catch {
                        self.hadErr.store(true, .release);
                        continue;
                    };

                    var prs = parser.Parser.init(self.arena.allocator(), self.context, tokens) catch {
                        self.hadErr.store(true, .release);
                        continue;
                    };

                    const imported = prs.parse() catch {
                        self.hadErr.store(true, .release);
                        continue;
                    };

                    const module = getModuleName(statement.value, ast, self.context);
                    self.pool.spawnWg(&self.wg, prepassImpl, .{self, self.context.getAST(imported), module});

                    file.dependencies.append(self.arena.allocator(), module) catch {
                        self.hadErr.store(true, .release);
                        continue;
                    };
                },
                else => { }
            }
        }

        self.lock.lock();
        defer self.lock.unlock();

        const index = self.modules.addOne(self.arena.allocator()) catch {
            self.hadErr.store(true, .release);
            return;
        };

        self.modules.set(index, file);
        self.moduleMap.put(self.arena.allocator(), file.name, index) catch {
            self.hadErr.store(true, .release);
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

    /// Leaks intermediate paths, but will be freed with the arena anyway.
    /// At the end, context will own the imported file paths.
    fn getModulePath(allocator: std.mem.Allocator, id: types.ExpressionPtr, ast: *const parser.AST, context: *Context) Error![]const u8 {
        const file = ast.tokens.items(.start)[0];
        const expr = ast.expressions.get(id);
        var res: []const u8 = "";

        // TODO: Rewrite in an iterative way
        switch (expr.type) {
            .Identifier => {
                res = ast.tokens.get(expr.value).lexeme(context, file);
            },
            .Scoping => {
                const lhsExpr = ast.extra[expr.value];
                const rhsExpr = ast.extra[expr.value + 1];

                const lhsStr = try getModulePath(allocator, lhsExpr, ast, context);
                const rhsStr = ast.tokens.get(rhsExpr).lexeme(context, file);

                return std.fmt.allocPrint(allocator, "{s}/{s}", .{lhsStr, rhsStr}) catch return error.AllocatorFailure;
            },
            else => unreachable,
        }

        return res;
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
        const expr = ast.expressions.get(id);
        switch (expr.type) {
            .Identifier => {
                return ast.tokens.items(.start)[expr.value];
            },
            .Scoping => {
                const lhs = ast.extra[expr.value]; 
                return getModuleNameStartIndex(lhs, ast);
            },
            else => unreachable,
        }
    }
};
