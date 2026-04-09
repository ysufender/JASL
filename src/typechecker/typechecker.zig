const std = @import("std");
const common = @import("../core/common.zig");
const defines = @import("../core/defines.zig");
const collections = @import("../util/collections.zig");

const Types = @import("type.zig");
const MultiArrayList = collections.MultiArrayList;
const ModuleList = @import("../parser/prepass.zig").ModuleList;
const Error = common.CompilerError;
const Context = common.CompilerContext;
const Allocator = std.mem.Allocator;
const Arena = std.heap.ArenaAllocator;
const TypeTable = MultiArrayList(Type);

pub const Type = struct {
    module: defines.ModulePtr,
    typeName: []const u8,
};

const Typechecker = @This();

arena: Arena,
context: *Context,
modules: ModuleList,

pub fn init(gpa: Allocator, context: *Context, modules: ModuleList) Error!Typechecker {
    const arena = Arena.init(gpa);

    return .{
        .arena = arena,
        .context = context,
        .modules = modules,
    };
}

pub fn typecheck(self: *Typechecker, allocator: Allocator) Error!TypeTable {
    defer self.arena.deinit();

    _ = allocator;
    return null;
}
