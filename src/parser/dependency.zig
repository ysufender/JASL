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
        path: u32,

        /// To prevent collections.deepCopy from copying the name
        /// since it is already a slice into context.
        pub fn dupe(self: *const Node, _: std.mem.Allocator) Error!Node {
            return .{
                .name = self.name,
                .path = self.path,
            };
        }
    };

//    pub const Iterator = struct {
//        items: LevelList,
//        level: u32,
//        cur: u32,
//
//        pub fn init(items: LevelList) Iterator {
//            return .{
//                .items = items,
//                .level = 0,
//                .cur = 0,
//            };
//        }
//
//        pub fn next(self: *Iterator) ?*Node {
//            self.level += @intCast(self.cur >= self.items[self.level].len);
//
//            if (self.level >= self.items.items.len) {
//                return null;
//            }
//
//            defer self.cur += 1;
//            return self.items[self.level][self.cur];
//        }
//    };

    levels: LevelList,
};

pub const Resolver = struct {
    const Self = @This();

    modules: *const ModuleList.Slice,
    context: *Context,
    arena: std.heap.ArenaAllocator,

    pub fn init(context: *Context, modules: *const ModuleList.Slice) Self {
        return .{
            .context = context,
            .modules = modules,
            .arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator),
        };
    }

    pub fn generate(self: *Self, allocator: std.mem.Allocator) Error!Graph {
        defer self.arena.deinit();

        var maxLevel: u32 = 0;
        var countsPerLevel: []u32 = undefined; 

        // Detect max dependency count and preallocate the levels array.
        var iterator = self.modules.iterator();
        while (iterator.next()) |module| {
            maxLevel = @intCast(@max(maxLevel, module.dependencies.items.len));
        }

        countsPerLevel = self.arena.allocator().alloc(u32, maxLevel + 1) catch return error.AllocatorFailure;
        for (0..countsPerLevel.len) |i| {
            countsPerLevel[i] = 0;
        }

        // Then detect counts per level.
        iterator.reset();
        while (iterator.next()) |module| {
            countsPerLevel[module.dependencies.items.len] += 1;
        }

        // And bulk-allocate necessary node space.
        const levels = self.arena.allocator().alloc(Level, maxLevel + 1) catch return error.AllocatorFailure;

        for (0..levels.len) |i| {
            const levelBuf = self.arena.allocator().alloc(Graph.Node, countsPerLevel[i]) catch return error.AllocatorFailure;
            levels[i] = .initBuffer(levelBuf);
        }

        iterator.reset();
        while (iterator.next()) |module| {
            levels[module.dependencies.items.len].appendAssumeCapacity(.{
                .name = module.name,
                .path = module.dataIndex,
            });
        }

        return .{
            .levels = try collections.deepCopySlice(Level, levels, allocator),
        };
    }
};
