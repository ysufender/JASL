const std = @import("std");
const defines = @import("../core/defines.zig");

// @CompilerOnly 
pub const TypeID = u32;

pub const TypeInfo = union(enum) {
    Struct: Struct,
    Union: Union,
    Enum: Enum,

    ComptimeInt, // Must be const
    ComptimeFloat, // Must be const
    EnumLiteral, // Must be const and comptime

    Integer: Integer,
    Bool: bool, // mutability bool
    Float: bool, // mutability bool
    Void,

    Pointer: Pointer,
    Function: Function, // is a pointer
    Noreturn,
    Any: bool, // mutability bool
    Type,

    Array: Array,
};

pub const FieldInfo = struct {
    public: bool,
    name: []const u8,
    valueType: TypeID,

    // @CompilerOnly 
    pub fn eql(this: *const FieldInfo, that: FieldInfo) bool {
        return
            this.public == that.public
            and std.mem.eql(u8, this.name, that.name)
            and this.valueType == that.valueType;
        // @Maybe TODO: Structural FieldInfo.valueType check instead.
    }
};

pub const Struct = struct {
    mutable: bool,
    name: []const u8,
    fields: []const FieldInfo,
    definitions: []const FieldInfo,

    // @CompilerOnly
    scope: defines.ScopePtr,
};

pub const Union = union(enum) {
    Tagged: struct {
        tag: TypeID,
        mutable: bool,
        name: []const u8,
        fields: []const FieldInfo,
        definitions: []const FieldInfo,

        // @CompilerOnly
        scope: defines.ScopePtr,
    },
    Plain: Struct,
};

pub const Enum = struct {
    mutable: bool,
    name: []const u8,
    fields: []const []const u8,
    definitions: []const FieldInfo,

    // @CompilerOnly
    scope: defines.ScopePtr,
};

pub const Pointer = struct {
    mutable: bool,
    child: TypeID,
    size: enum {
        Slice,
        Single,
        C,
    },
};

pub const Array = struct {
    mutable: bool,
    child: TypeID,
    len: u32,
};

pub const Function = struct {
    mutable: bool,
    argTypes: []const TypeID,
    returnType: TypeID,
};

pub const Integer = struct {
    mutable: bool,
    size: u6,
    signed: bool,

    // @CompilerOnly 
    pub const Range = struct { 
        min: i64,
        max: i64,
    };

    // @CompilerOnly 
    pub fn range(self: Integer) Range {
        const max =
            if (self.size == 0) 0
            else (@as(i64, 1) << (self.size - @intFromBool(self.signed))) - 1;

        const min =
            if (!self.signed) 0
            else if (self.size == 0) 0
            else -(@as(i64, 1) << (self.size - 1));

        return .{
            .min = min,
            .max = max,
        };
    }

    // @CompilerOnly 
    pub fn canContain(self: Integer, other: Integer) bool {
        const selfRange = self.range();
        const otherRange = other.range();

        return
            selfRange.min <= otherRange.min
            and selfRange.max >= otherRange.max;
    }
};
