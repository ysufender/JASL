const std = @import("std");
const common = @import("../core/common.zig");
const defines = @import("../core/defines.zig");
const collections = @import("../util/collections.zig");
const Types = @import("type.zig");

const Parser = @import("../parser/parser.zig");
const Typechecker = @import("typechecker.zig");
const ResolutionKey = defines.ResolutionKey;
const Allocator = std.mem.Allocator;
const Arena = std.heap.ArenaAllocator;
const Error = common.CompilerError;

const CacheEntryLookup = defines.LookupMap(defines.DeclPtr, CacheLookup);
const CacheLookup = defines.LookupMap([]const Value, Value);

const ValuePtr = u32;

// TODO: Turn into a manually tagged union
// with possibly flattened fields for performance
// and memory usage
pub const Value = union(enum) {
    Int: u32,
    Float: f32,
    String: []const u8,
    Bool: bool,
    Enum: struct {
        Type: Types.TypeID,
        Value: u32,
    },
    Union: struct {
        Type: Types.TypeID,
        Tag: u32,
        Value: ValuePtr,
    },

    Struct: struct {
        Type: Types.TypeID,
        Fields: []const ValuePtr,
    },

    Type: Types.TypeID,
    Pointer: struct {
        Type: enum {
            Slice,
            Single,
            C,
        },
    },
    Function: void,
    Void: void,
};

const Comptime = @This();

cache: CacheEntryLookup,
typechecker: *Typechecker,
arena: Arena,
gpa: Allocator,

pub fn init(typechecker: *Typechecker, gpa: Allocator) Error!Comptime {
    var arena = Arena.init(gpa);
    const allocator = arena.allocator();

    var cache = CacheEntryLookup.empty;
    cache.ensureTotalCapacity(allocator, 256) catch return error.AllocatorFailure;

    return .{
        .typechecker = typechecker,
        .gpa = gpa,
        .cache = cache,
        .arena = arena,
    };
}

pub fn deinit(self: *Comptime) void {
    self.arena.deinit();
}
