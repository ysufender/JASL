pub const TypeID = u32;

pub const TypeInfo = union(enum) {
    Struct: Struct,
    Union: Union,
    Enum: Enum,

    ComptimeInt: void, // Must be const
    ComptimeFloat: void, // Must be const

    Integer: Integer,
    Bool: bool, // mutability bool
    Float: bool, // mutability bool
    Void: void,

    Pointer: Pointer,
    Function: Function,
    Noreturn: void,
    Any: bool, // mutability bool
    Type: void,

    Array: Array,
};

pub const FieldInfo = struct {
    public: bool,
    name: []const u8,
    valueType: TypeID,
};

pub const Struct = struct {
    mutable: bool,
    name: []const u8,
    fields: []const FieldInfo,
    definitions: []const FieldInfo,
};

pub const Union = Struct;

pub const Enum = struct {
    mutable: bool,
    name: []const u8,
    fields: []const []const u8,
    definitions: []const FieldInfo,
};

pub const Pointer = struct {
    mutable: bool,
    child: TypeID,
    pointerType: enum {
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
    name: []const u8,
    argTypes: []const TypeID,
    returnTypes: []const TypeID,
};

pub const Integer = struct {
    mutable: bool,
    size: u8,
    signed: bool,
};
