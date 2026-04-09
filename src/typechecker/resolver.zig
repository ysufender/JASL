const std = @import("std");
const common = @import("../core/common.zig");
const defines = @import("../core/defines.zig");
const collections = @import("../util/collections.zig");

const MultiArrayList = collections.MultiArrayList;
const ModuleList = @import("../parser/prepass.zig").ModuleList;
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
        Struct,
        Union,
        Enum,
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
    };

    scope: defines.ScopePtr,
    public: bool,
    name: defines.TokenPtr,
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

const Resolver = @This();

arena: Arena,
context: *Context,
scopes: ScopeList,
lookup: LookupMap,
decls: DeclarationList,
reso: ResolutionMap,
currentScope: defines.ScopePtr,
moduleCount: u32,

pub fn init(gpa: Allocator, context: *Context, modules: ModuleList) Error!Resolver {
    var arena = Arena.init(gpa);
    const allocator = arena.allocator();

    const scopeCap = (context.counts.statements / 4) + context.counts.modules;
    const declCap = (context.counts.expressions / 8) + context.counts.topLevel;

    var scopes = try ScopeList.init(allocator, scopeCap);
    var decls = try DeclarationList.init(allocator, declCap);
    var lookup = LookupMap.empty;
    var reso = ResolutionMap.empty;

    lookup.ensureTotalCapacity(allocator, declCap) catch return error.AllocatorFailure;
    reso.ensureTotalCapacity(allocator, declCap) catch return error.AllocatorFailure;

    var iterator = modules.modules.iterator();
    while (iterator.next()) |module| {
        const tokens = context.getTokens(module.dataIndex);

        const scope = try scopes.addOne(allocator);
        scopes.set(scope, .{
            .parent = null,
            .module = modules.ids.get(module.name).?,
            .kind = .Module,
        });

        var siterator = module.symbols.iterator();
        while (siterator.next()) |symbol| {
            const name = tokens.get(symbol.name).lexeme(context, module.dataIndex);

            const decl = try decls.addOne(allocator);
            decls.set(decl, .{
                .scope = scope,
                .public = symbol.public,
                .name = symbol.name,
                .node = symbol.value,
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
        .reso = reso,
        .moduleCount = modules.modules.len,
        .currentScope = 0,
    };
}

pub fn resolve(self: *Resolver, _: Allocator) Error!ResolutionMap {
    for (0..self.moduleCount) |i| {
        self.currentScope = @intCast(i);
        try self.resolveModule();
    }
    return undefined;
}

fn resolveModule(_: *Resolver) Error!void {
}

fn look(self: *Resolver, namePtr: []const u8) ?defines.DeclPtr {
    var current: ?defines.ScopePtr = self.currentScope;
    while (current) |s| {
        if (self.lookup.get(.{ .scope = s, .name = namePtr })) |declPtr| {
            const module = self.scopes.items(.module)[self.decls.items(.scope)[declPtr]];
            const public = self.decls.items(.public)[declPtr];

            if (public or module == self.currentScope) {
                return declPtr;
            }
        }
        current = self.scopes.items(.parent)[s];
    }
    return null;
}
