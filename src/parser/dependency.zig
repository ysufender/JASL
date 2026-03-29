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
            std.debug.print("{s} {any}\n", .{self.name, self.depends});

            return .{
                .name = self.name,
                .depends = try collections.deepCopy(self.depends, allocator),
            };
        }
    };

    nodes: []Node,

    pub fn init(allocator: std.mem.Allocator, size: u32) Error!Self {
        return .{
            .nodes = allocator.alloc(Node, size) catch return error.AllocatorFailure,
        };
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
            _ = try self.generateNode(@intCast(i), 0, &graph);
        }
        
        return collections.deepCopy(graph, owner);
    }

    fn generateNode(self: *Self, moduleIndex: u32, _graphIndex: u32, graph: *Graph) Error!u32 {
        const allocator = self.arena.allocator();
        var graphIndex = _graphIndex;

        const name = self.modules.modules.items(.name)[moduleIndex];

        if (self.resolved.get(name)) |node| {
            return node;
        }

        const dependencies = self.modules.modules.items(.dependencies)[moduleIndex].items;

        var depends = allocator.alloc(defines.Offset, dependencies.len) catch return error.AllocatorFailure;
        self.resolved.putAssumeCapacityNoClobber(name, graphIndex);
        graph.nodes[graphIndex] = .{
            .name = name,
            .depends = depends,
        };

        for (dependencies, 0..) |dependency, i| {
            defer graphIndex += 1;
            depends[i] = try self.generateNode(self.modules.ids.get(dependency).?, graphIndex, graph);
        }
 
        return graphIndex;
    }
};
