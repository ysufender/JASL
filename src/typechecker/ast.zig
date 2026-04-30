const defines = @import("../core/defines.zig");
const types = @import("type.zig");

const TypeID = types.TypeID;

pub const Program = []Unit;

pub const Unit = struct {
    moduleID: defines.ModulePtr,
    globals: []const Symbol,
};

pub const Symbol = struct {
    /// Mangled, full name.
    name: []const u8,
    /// Global index
    index: u32,
    initializer: Operation,
};

pub const Operation = union(enum) {
};
