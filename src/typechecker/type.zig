pub const TypeInfo = union(enum) {
    Struct: Struct,
    Union: Union,
    Enum: Enum,

    Integer: Integer,
    Bool: bool, // mutability bool
    Float: bool, // mutability bool
    Void: void,

    Pointer: Pointer,
    Function: Function,
    Noreturn: void,
    Any: void,
    Type: void,
};

pub const FieldInfo = struct {
    public: bool,
    name: []u8,
    valueType: type,
};

pub const Struct = struct {
    mutable: bool,
    name: []u8,
    fields: []FieldInfo,
    definitions: []FieldInfo,
};

pub const Union = Struct;

pub const Enum = struct {
    mutable: bool,
    name: []u8,
    fields: [][]u8,
    definitions: []FieldInfo,
};

pub const Pointer = struct {
    mutable: bool,
    child: type,
    pointerType: enum {
        Slice,
        Single,
    },
};

pub const Function = struct {
    mutable: bool,
    name: []u8,
    argTypes: []type,
    returnTypes: []type,
};

pub const Integer = struct {
    mutable: bool,
    size: u8,
    signed: bool,
};
