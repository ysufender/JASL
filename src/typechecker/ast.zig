const defines = @import("../core/defines.zig");

pub const Operation = struct {
    pub const Type = enum {
        VariableDefinition,
        // TODO
    };

    type: Type,
    value: defines.OpaquePtr,
};
