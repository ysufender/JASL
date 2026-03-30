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
    const Self = @This();

    pub const Node = struct {
        name: []const u8,
        depends: []const defines.Offset,

        pub fn dupe(self: *const Node, allocator: std.mem.Allocator) Error!Node {
            return .{
                .name = self.name,
                .depends = try collections.deepCopy(self.depends, allocator),
            };
        }
    };

    pub const Iterator = struct {
        nodes: []const Node,
        index: u32,
        dep: u32,
        visited: std.DynamicBitSetUnmanaged,
        history: collections.StaticStack(collections.Pair(u32)),

        pub fn init(nodes: []const Node, allocator: std.mem.Allocator) Iterator {
            return .{
                .nodes = nodes,
                .visited = std.DynamicBitSetUnmanaged.initFull(allocator, nodes.len),
                .idx = 0,
                .dep = 0,
                .history = try collections.StaticStack(collections.Pair(u32)).init(nodes.len, allocator),
            };
        }

        pub fn next(self: *Iterator) ?Node {
            // TODO: Continue
            if (self.dep < self.nodes[self.index].depends.len) {
                const depIdx = self.nodes[self.index].depends[self.dep];
                self.history.push(.init(self.index, self.dep)) catch {};
                self.visited.set(depIdx);

                self.index = depIdx;
                self.dep = 0;
            }
        }
    };

    nodes: []Node,

    pub fn init(allocator: std.mem.Allocator, size: u32) Error!Self {
        return .{
            .nodes = allocator.alloc(Node, size) catch return error.AllocatorFailure,
        };
    }

    pub fn iterator(self: *Self) collections.Iterator(Iterator, Node) {
    }
};

pub const Resolver = struct {
    const Self = @This();

    modules: *const ModuleList,
    context: *Context,
    arena: std.heap.ArenaAllocator,
    resolved: std.StringHashMapUnmanaged(defines.Offset),
    lock: defines.Lock,

    pub fn init(context: *Context, modules: *const ModuleList) Self {
        return .{
            .context = context,
            .modules = modules,
            .arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator),
            .resolved = .empty,
            .lock = .{},
        };
    }

    pub fn generate(self: *Self, owner: std.mem.Allocator) Error!Graph {
        defer self.arena.deinit();

        const allocator = self.arena.allocator();

        self.resolved.ensureTotalCapacity(allocator, self.modules.modules.len) catch return error.AllocatorFailure;

        var graph = try Graph.init(allocator, self.modules.modules.len);

        for (0..self.modules.modules.len) |i| {
            _ = try self.generateNode(@intCast(i), &graph);
        }

        return collections.deepCopy(graph, owner);
    }

    fn generateNode(self: *Self, moduleIndex: u32, graph: *Graph) Error!u32 {
        const allocator = self.arena.allocator();

        const name = self.modules.modules.items(.name)[moduleIndex];

        if (self.resolved.get(name)) |node| {
            return node;
        }

        const dependencies = self.modules.modules.items(.dependencies)[moduleIndex].items;

        var depends = allocator.alloc(defines.Offset, dependencies.len) catch return error.AllocatorFailure;
        const idx = self.resolved.size;
        self.resolved.putAssumeCapacityNoClobber(name, idx);

        for (dependencies, 0..) |dependency, i| {
            depends[i] = try self.generateNode(self.modules.ids.get(dependency).?, graph);
        }
 
        graph.nodes[idx] = .{
            .name = name,
            .depends = depends,
        };
        return idx;
    }
};
