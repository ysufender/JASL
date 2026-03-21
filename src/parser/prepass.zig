const std = @import("std");
const parser = @import("parser.zig");
const common = @import("../core/common.zig");
const types = @import("../core/types.zig");
const arraylist = @import("../util/arraylist.zig");

const CompilerContext = common.CompilerContext;

/// Contains both public and private top level
/// symbols.
pub const Module = struct {
    pub const Symbol = struct {
        name: types.TokenPtr,
        value: types.ExpressionPtr,
    };

    /// namespace of the module, a range into
    /// the token list.
    name: types.Range,

    /// Also file and token list index
    ast: types.ASTPtr,

    symbolPtrs: std.StringHashMapUnmanaged(types.SymbolPtr),
    symbols: arraylist.MultiArrayList(Symbol),
};

pub const ModuleList = arraylist.MultiArrayList(Module);

pub const Prepass = struct {
    const Self = @This();

    lock: types.Lock,
    modulePtrs: std.StringHashMapUnmanaged(types.ModulePtr),
    modules: ModuleList,
    arena: std.heap.ArenaAllocator,
    context: *CompilerContext,
    main: types.ASTPtr,

    pub fn init(baseAllocator: std.mem.Allocator, context: *CompilerContext, main: types.ASTPtr) common.CompilerError!Self {
        var arena = std.heap.ArenaAllocator.init(baseAllocator);

        const ast = context.getAST(main);

        return .{
            .arena = arena,
            .lock = .{},
            .modulePtrs = .empty,
            .modules = try ModuleList.init(arena.allocator(),  ast.tokens.len / 32),
            .context = context,
            .main = main,
        };
    }

    pub fn prepass(_: *Self) common.CompilerError!ModuleList.Slice {
        return undefined;
    }
};

const ResultPtr = u32;
