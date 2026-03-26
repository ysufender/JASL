const std = @import("std");
const common = @import("../core/common.zig");
const prepass = @import("prepass.zig");
const defines = @import("../core/defines.zig");
const collections = @import("../util/collections.zig");

const Module = prepass.Module;
const ModuleList = prepass.ModuleList;
const Context = common.CompilerContext;
const Error = common.CompilerError;
const Level = std.ArrayList(Graph.Node);
const LevelList = []const Level;

/// Does not resolve circular dependencies, such dependencies
/// should be handled in typechecking by waiting for dependencies
/// to be handle e.g. marking unknowns as waiting/resolved etc..
pub const Graph = struct {
    pub const Node = struct {
        name: []const u8,
        depends: []const *const Node,

        pub fn dupe(self: *const Node, allocator: std.mem.Allocator) Error!Node {
            return .{
                .name = self.name,
                .depends = try collections.deepCopy(self.depends, allocator),
            };
        }
    };

    head: *const Node = @ptrFromInt(@alignOf(*Node)),
};

pub const Resolver = struct {
    const Self = @This();

    modules: *const ModuleList.Slice,
    context: *Context,
    arena: std.heap.ArenaAllocator,
    resolved: std.StringHashMap(void),
    lock: defines.Lock,

    pub fn init(context: *Context, modules: *const ModuleList.Slice) Self {
        return .{
            .context = context,
            .modules = modules,
            .arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator),
            .resolved = undefined,
            .lock = .{},
        };
    }

    pub fn generate(self: *Self, owner: std.mem.Allocator) Error!Graph {
        const allocator = self.arena.allocator();
        self.resolved = .init(allocator);
        defer self.arena.deinit();

        self.resolved = .init(allocator);
        self.resolved.ensureTotalCapacity(self.modules.len) catch return error.AllocatorFailure;

        var graph = Graph{};

        var maxLevel: u32 = 0;

        // Detect max dependency count and preallocate the levels array.
        for (self.modules.items(.dependencies)) |deps| {
            maxLevel = @intCast(@max(maxLevel, deps.items.len));
        }

        for (self.modules.items(.dependencies), 0..) |deps, i| {
            if (deps.items.len < maxLevel) {
                @branchHint(.likely);
                continue;
            }

            if (self.resolved.contains(self.modules.items(.name)[i])) {
                continue;
            }

            graph.head = try self.generateNode(@intCast(i));
        }

        return collections.deepCopy(graph, owner);
    }

    fn generateNode(self: *Self, _: u32) Error!*const Graph.Node {
        const allocator = self.arena.allocator();

        const node = allocator.create(Graph.Node) catch return error.AllocatorFailure;
        node.* = .{
            .name = "",
            .depends = &.{},
        };

        return node;
    }
};
