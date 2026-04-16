const std = @import("std");
const common = @import("../core/common.zig");
const defines = @import("../core/defines.zig");
const collections = @import("../util/collections.zig");
const Types = @import("type.zig");

const Comptime = @import("comptime.zig");
const Resolver = @import("resolver.zig");
const ModuleList = @import("../parser/prepass.zig").ModuleList;
const TypeInfo = Types.TypeInfo;
const TypeID = Types.TypeID;
const MultiArrayList = collections.MultiArrayList;
const Error = common.CompilerError;
const Context = common.CompilerContext;
const Arena = std.heap.ArenaAllocator;
const Allocator = std.mem.Allocator;
const ResolutionKey = defines.ResolutionKey;

const deepCopy = collections.deepCopy;
const assert = std.debug.assert;

pub const TypeTable = MultiArrayList(TypeInfo);
pub const TypeMap = defines.LookupMap(TypeInfo, TypeID);
pub const ResolutionMap = defines.LookupMap(defines.DeclPtr, defines.Range);
pub const MetadataMap = defines.LookupMap(Element, []const defines.ExpressionPtr);
const LookupMap = defines.LookupMap(defines.DeclPtr, TypecheckStatus);

const TypecheckStatus = struct {
    status: enum {
        Checked,
        InProgress,
        NotChecked,
    },

    types: defines.Range,
};

pub const Element = struct {
    kind: enum {
        Statement,
        Expression,
    },
    value: defines.OpaquePtr,
};

pub const Constant = struct {
    pub const Type = enum {
        Integer,
        Float,
        String,
        Bool,
        Aggregate,
    };

    type: Type,
    value: defines.OpaquePtr,
};

pub const Constants = struct {
    pub const List = collections.MultiArrayList(Constant);
    pub const Integer = std.ArrayList(u32);
    pub const Float = std.ArrayList(f32);
    pub const String = std.ArrayList([]const u8);
    pub const Bool = std.ArrayList(bool);
    pub const Aggregate = std.ArrayList([]const Constant);

    all: List,
    ints: Integer,
    floats: Float,
    strings: String,
    bools: Bool,
    aggs: Aggregate,
};

pub const Resolution = struct {
    types: TypeTable.Slice,
    resolutionMap: ResolutionMap,
    constants: Constants,

    pub fn tryGet(self: *const Resolution, key: ResolutionKey) ?TypeID {
        return self.resolutionMap.get(key);
    }

    pub fn get(self: *const Resolution, key: ResolutionKey) TypeID {
        return self.tryGet(key).?;
    }

    pub fn tryGetType(self: *const Resolution, key: ResolutionKey) ?TypeInfo {
        return self.types.get(self.tryGet(key) orelse return null);
    }

    pub fn getType(self: *const Resolution, key: ResolutionKey) TypeInfo {
        return self.tryGetType(key).?;
    }
};

const Typechecker = @This();

arena: Arena,
context: *Context,
modules: *const ModuleList,
symbols: *const Resolver.Resolution,

constants: Constants,
typeTable: TypeTable,
typeMap: TypeMap,
lookup: LookupMap,
metadata: MetadataMap,
reso: ResolutionMap,

executer: Comptime,

currentFile: defines.FilePtr,
lastToken: defines.TokenPtr,

scratch: std.ArrayList(TypeID),
extra: std.ArrayList(TypeID),

pub fn init(
    gpa: Allocator,
    context: *Context,
    modules: *const ModuleList,
    symbolTable: *const Resolver.Resolution
) Error!Typechecker {
    var arena = Arena.init(gpa);
    const allocator = arena.allocator();

    const counts = context.counts;
    const total = counts.integer + counts.float + counts.string + counts.bool;
    const typeCount = counts.types * 3 + @as(u32, @intCast(builtins.len));

    var typeTable = try TypeTable.init(allocator, typeCount + @as(u32, @intCast(builtins.len)));
    var extra = std.ArrayList(TypeID).initCapacity(allocator, typeCount) catch return error.AllocatorFailure;
    var reso = ResolutionMap.empty;
    var typeMap = TypeMap.empty;
    var metadata = MetadataMap.empty;
    var lookup = LookupMap.empty;

    reso.ensureTotalCapacity(allocator, symbolTable.declarations.len) catch return error.AllocatorFailure;
    typeMap.ensureTotalCapacity(allocator, typeCount + @as(u32, @intCast(builtins.len))) catch return error.AllocatorFailure;
    lookup.ensureTotalCapacity(allocator, symbolTable.declarations.len) catch return error.AllocatorFailure;
    metadata.ensureTotalCapacity(allocator, counts.meta * 3) catch return error.AllocatorFailure;

    inline for (builtins, 0..) |builtin, id| {
        typeTable.appendAssumeCapacity(std.meta.activeTag(builtin.info), @field(builtin.info, @tagName(std.meta.activeTag(builtin.info))));
        typeMap.putAssumeCapacityNoClobber(.{ .name = builtin.info, .scope = 0 }, @intCast(id));
        extra.appendAssumeCapacity(id);
    }

    return .{
        .context = context,
        .modules = modules,
        .typeTable = typeTable,
        .reso = reso,
        .typeMap = typeMap,
        .metadata = metadata,
        .lookup = lookup,
        .scratch = std.ArrayList(TypeID).initCapacity(allocator, 128) catch return error.AllocatorFailure,
        .extra = extra,
        .constants = .{
            .all = try Constants.List.init(allocator, total * 2),
            .ints = Constants.Integer.initCapacity(allocator, (counts.integer * 3) / 2) catch return error.AllocatorFailure,
            .floats = Constants.Float.initCapacity(allocator, (counts.float * 3) / 2) catch return error.AllocatorFailure,
            .strings = Constants.String.initCapacity(allocator, (counts.string * 3) / 2) catch return error.AllocatorFailure,
            .bools = Constants.Bool.initCapacity(allocator, (counts.bool * 3) / 2) catch return error.AllocatorFailure,
            .aggs = Constants.Aggregate.initCapacity(allocator, total / 2) catch return error.AllocatorFailure,
        },
        .executer = undefined,
        .symbols = symbolTable,
        .currentFile = 0,
        .lastToken = 0,
        .arena = arena,
    };
}

pub fn typecheck(self: *Typechecker, allocator: Allocator) Error!Resolution {
    self.currentFile = self.modules.getItem("root", .dataIndex).*;
    
    if (!self.modules.getItem("root", .symbolPtrs).contains("main")) {
        self.report("Couldn't find an entry point in the root module.", .{});
        return error.MissingEntry;
    }

    defer self.arena.deinit();
    self.executer = try Comptime.init(self, allocator);

    const mainType = try self.typecheckDecl(self.symbols.lookup.get(.{ .scope = 1, .name = "main" }).?);
    if (mainType.len() != 1 or self.extra.items[mainType.start] != Builtin.Type("entry_point").start) {
        self.report("Unexpected type of entry point 'main'. Expected '*fn void -> i32', received '{s}'", .{
            try self.typeName(allocator, self.extra.items[mainType.start]),
        });
        return error.TypeMismatch;
    }

    return .{
        .types = (self.typeTable.slice()), 
        .resolutionMap = (self.reso),
        .constants = (self.constants),
    };
}

pub fn typecheckStatement(self: *Typechecker, statementPtr: defines.StatementPtr) Error!defines.Range {
    const allocator = self.arena.allocator();
    const ast = self.context.getAST(self.currentFile);
    const tokens = self.context.getTokens(self.currentFile);

    const statement = ast.statements.get(statementPtr);
    return ret: switch (statement.type) {
        .VariableDefinition => {
            const exprPtr = ast.extra.items[statement.value + 2];
            const initializer = try self.typecheckExpression(exprPtr, null);

            const signatures = defines.Range{
                .start = ast.extra.items[statement.value],
                .end = ast.extra.items[statement.value + 1],
            };

            if (signatures.len() != initializer.len()) {
                self.report(
                    "Expression count mismatch in variable definition."
                    ++ "\n\tExpected {d} expressions, received {d}.", .{
                        signatures.len(),
                        initializer.len() 
                });
                break :ret error.IllegalSyntax;
            }

            const scratchStart = self.scratch.items.len;
            for (signatures.start..signatures.end) |signaturePtrPtr| {
                const index = @as(u32, @intCast(signaturePtrPtr)) - signatures.start;
                const signaturePtr = ast.extra.items[signaturePtrPtr];
                self.lastToken = ast.signatures.items(.name)[signaturePtr];
                const declTypePtr: defines.ExpressionPtr = ast.signatures.items(.type)[signaturePtr];
                const declTypeRange = try self.typecheckExpression(declTypePtr, comptime Builtin.Type("type"));

                switch (declTypeRange.len()) {
                    1 => {
                        const declType: TypeID = declTypeRange.start;
                        const initializerType: TypeID = initializer.at(index);

                        if (!self.suitableSingle(declType, initializerType)) {
                            self.report("Mismatching initializer type for '{s}'. Expected '{s}', received '{s}'.", .{
                                tokens.get(self.lastToken).lexeme(self.context, self.currentFile),
                                try self.typeName(allocator, declType),
                                try self.typeName(allocator, initializerType),
                            });
                            return error.TypeMismatch;
                        }

                        self.scratch.append(allocator, self.assign(declType, initializerType, true)) catch return error.AllocatorFailure;
                    },
                    0 => {
                        self.report("Untyped declarations are not supported.", .{});
                        break :ret error.IllegalSyntax;
                    },
                    else => {
                        self.report("Multi-typed declarations are not supported.", .{});
                        break :ret error.IllegalSyntax;
                    },
                }
            } 

            const types = try self.commitScratch(scratchStart);
            return types;
        },
        else => {
            self.report("Typechecking is not implemented for {s}", .{@tagName(statement.type)});
            break :ret error.NotImplemented;
        },
    };
}

pub fn typecheckExpression(self: *Typechecker, expressionPtr: defines.ExpressionPtr, maybeExpected: ?defines.Range) Error!defines.Range {
    const allocator = self.arena.allocator();
    const ast = self.context.getAST(self.currentFile);
    const tokens = self.context.getTokens(self.currentFile);

    const expr = ast.expressions.get(expressionPtr);
    return ret: switch (expr.type) {
        .Literal => switch (tokens.items(.type)[expr.value]) {
            .Integer => comptime Builtin.Type("comptime_int"),
            .Float => comptime Builtin.Type("comptime_float"),
            .False, .True => comptime Builtin.Type("bool"),
            .String => comptime Builtin.Type("string"),
            .EnumLiteral => {
                if (maybeExpected) |expected| {
                    if (expected.len() > 1) {
                        self.report("Unexpected enum literal.", .{});
                    }

                    switch (self.typeTable.tag()[expected.start]) {
                        .Enum => {
                            const literal = tokens.get(expr.value).lexeme(self.context, self.currentFile)[1..];
                            const fields: Types.Enum = self.typeTable.get(.Enum, expected.start);

                            for (fields.fields) |field| {
                                if (std.mem.eql(u8, field, literal)) {
                                    break :ret expected;
                                }
                            }

                            self.report("Enum type {s} does not contain a field named {s}.", .{try self.typeName(allocator, expected.start), literal[1..]});
                            break :ret error.InvalidEnumeration;
                        },
                        else => {
                            self.report("Expected {s}, received enum literal instead.", .{try self.typeName(allocator, expected.start)});
                            break :ret error.TypeMismatch;
                        }
                    }
                }
                else {
                    self.report("Unable to infer result type of enum literal.", .{});
                    break :ret error.MissingTypeSpecifier;
                }
            },
            else => unreachable,
        },
        .ValueType =>
            if (expr.value == 0) comptime Builtin.Type("any")
            else break :ret self.typecheckDecl(self.symbols.get(.{ .file = self.currentFile, .expr = expressionPtr })),
        .ExpressionList => {
            const expressions = defines.Range{
                .start = ast.extra.items[expr.value],
                .end = ast.extra.items[expr.value + 1],
            };

            for (expressions.start..expressions.end) |exprPtrPtr| {
                const exprType = try self.typecheckExpression(ast.extra.items[exprPtrPtr], maybeExpected);
                _ = exprType;
            }

            break :ret std.mem.zeroes(defines.Range);
        },
        .Identifier => 
            if (self.symbols.resolutionMap.get(.{ .file = self.currentFile, .expr = expressionPtr })) |decl|
                try self.typecheckDecl(decl)
            else unreachable,
        else => {
            self.report("Typechecking is not implemented for {s}", .{@tagName(expr.type)});
            break :ret error.NotImplemented;
        },
    };
}

pub fn typecheckDecl(self: *Typechecker, declPtr: defines.DeclPtr) Error!defines.Range {
    const allocator = self.arena.allocator();

    const isPresent = self.lookup.getOrPut(allocator, .{ .scope = self.currentFile, .name = declPtr }) catch return error.AllocatorFailure;

    return if (isPresent.found_existing) ret: switch (isPresent.value_ptr.status) {
        .InProgress => {
            self.report("Dependency cycle detected.", .{});
            break :ret error.DependencyCycle;
        },
        .Checked => return isPresent.value_ptr.types,
        else => unreachable,
    }
    else ret: {
            isPresent.value_ptr.* = .{
                .status = .InProgress,
                .types = std.mem.zeroes(defines.Range),
            };

            const decl = self.symbols.declarations.get(declPtr);
            const declType = blk: switch (decl.kind) {
                .Variable => {
                    self.lastToken = decl.token;
                    break :blk try self.typecheckStatement(decl.node);
                },
                .Builtin => {
                    break :ret if (decl.index <= 8) defines.Range{ .start = decl.index, .end = decl.index + 1 }
                    else error.NotImplemented;
                },
                else => {
                    self.report("Typechecking is not implemented for {s}", .{@tagName(decl.kind)});
                    break :ret error.NotImplemented;
                },
            };

            isPresent.value_ptr.* = .{
                .status = .Checked,
                .types = declType,
            };

            break :ret declType;
    };
}

fn report(self: *const Typechecker, comptime fmt: []const u8, args: anytype) void {
    common.log.err(fmt, args);
    const token = self.context.getTokens(self.currentFile).get(self.lastToken);
    const position = token.position(self.context, self.currentFile);
    common.log.err("\t{s} {d}:{d}\n", .{ self.context.getFileName(self.currentFile), position.line, position.column});
}

fn suitable(self: *const Typechecker, expected: defines.Range, got: defines.Range) bool {
    _ = self;

    return
        if (expected.len() != got.len()) false
        else {
        };
}

fn suitableSingle(self: *const Typechecker, expected: TypeID, got: TypeID) bool {
    return switch (self.typeTable.tag()[got]) {
        .Noreturn => true,
        else => |_| switch (self.typeTable.tag()[expected]) {
            .Any => true,
            else => false,
        },
    };
}

fn assignable(self: *const Typechecker, this: TypeID, that: TypeID) bool {
    return
        if (!self.mutable(this)) false
        else if (this == that) true
        else switch (self.typeTable.tag()[this]) {
            else => unreachable,
        };
}

fn assign(self: *const Typechecker, this: TypeID, that: TypeID, initialize: bool) TypeID {
    assert(initialize or self.assignable(this, that));

    return switch (self.typeTable.tag()[this]) {
        .Any =>
            if (self.typeTable.get(.Any, this) or initialize) that
            else unreachable,
        else => this,
    };
}

fn mutable(self: *const Typechecker, typeID: TypeID) bool {
    return switch (self.typeTable.tag()[typeID]) {
        .ComptimeInt, .ComptimeFloat => false,
        .Any => self.typeTable.get(.Float, typeID),
        .Bool => self.typeTable.get(.Float, typeID),
        .Float => self.typeTable.get(.Float, typeID),
        .Struct => self.typeTable.get(.Struct, typeID).mutable,
        .Union => self.typeTable.get(.Union, typeID).mutable,
        .Enum => self.typeTable.get(.Enum, typeID).mutable,
        .Integer => self.typeTable.get(.Integer, typeID).mutable,
        .Pointer => self.typeTable.get(.Pointer, typeID).mutable,
        .Function => self.typeTable.get(.Function, typeID).mutable,
        else => false,
    };
}

fn typeName(self: *const Typechecker, allocator: Allocator, typeID: TypeID) Error![]const u8 {
    const typename = struct {
        fn typename(this: *const Typechecker, comptime T: std.meta.FieldEnum(TypeInfo), alc: Allocator, tid: TypeID) Error![]const u8 {
            const t = this.typeTable.get(T, tid);
            
            const prefix = if (t.mutable) "" else "mut ";

            const res = alc.alloc(u8, prefix.len + t.name.len) catch return error.AllocatorFailure;
            return std.fmt.bufPrint(res, "{s}{s}", .{prefix, t.name}) catch unreachable;
        }
    }.typename;

    return
        if (Builtin.isBuiltin(typeID)) Builtin.TypeName(typeID)
        else ret: switch (self.typeTable.tag()[typeID]) {
            .Struct => typename(self, .Struct, allocator, typeID),
            .Union => typename(self, .Union, allocator, typeID),
            .Enum => typename(self, .Enum, allocator, typeID),
            .Function => typename(self, .Function, allocator, typeID),
            .Pointer => {
                const ptr: Types.Pointer = self.typeTable.get(.Pointer, typeID);
                const child = try self.typeName(allocator, ptr.child);

                const prefix = switch (ptr.pointerType) {
                    .Slice => "[]",
                    .Single => "*",
                    .C => "[@c]",
                };

                const res = allocator.alloc(u8, child.len + prefix.len) catch break :ret error.AllocatorFailure;
                break :ret std.fmt.bufPrint(res, "{s}{s}", .{prefix, child}) catch unreachable;
            },
            .Array => {
                const arr: Types.Array = self.typeTable.get(.Array, typeID);
                const child = try self.typeName(allocator, arr.child);

                const prefix = if (arr.mutable) "mut " else "";

                const res = allocator.alloc(u8, child.len + prefix.len) catch break :ret error.AllocatorFailure;
                break :ret std.fmt.bufPrint(res, "{s}{s}", .{prefix, child}) catch unreachable;
            },
            else => unreachable,
        };
}

fn commitFromSlice(self: *Typechecker, items: []const defines.OpaquePtr) common.CompilerError!defines.Range {
    const allocator = self.arena.allocator();
    const start: defines.OpaquePtr = @intCast(self.extra.items.len);
    self.extra.appendSlice(allocator, items) catch return error.AllocatorFailure;
    return .{
        .start = start,
        .end = @intCast(self.extra.items.len)
    };
}

fn commitScratch(self: *Typechecker, scratchStart: usize) common.CompilerError!defines.Range {
    const span = try self.commitFromSlice(self.scratch.items[scratchStart..]);
    self.scratch.shrinkRetainingCapacity(@intCast(scratchStart));
    return span;
}

const Builtin = struct {
    fn isBuiltin(typeID: TypeID) bool {
        return typeID < builtins.len;
    }

    fn TypeName(btype: TypeID) []const u8 {
        assert(btype < builtins.len);
        return builtins[btype].name;
    }

    fn Type(btype: []const u8) defines.Range {
        for (builtins, 0..) |item, i| {
            if (std.mem.eql(u8, item.name, btype)) {
                return .{
                    .start = @intCast(i),
                    .end = @intCast(i + 1),
                };
            }
        }

        unreachable;
    }
};

const builtins = [_]struct {
    name: []const u8,
    info: TypeInfo,
}{
    // u32
    .{ .name = "u32", .info = .{ .Integer = .{ .mutable = false, .size = 32, .signed = false, } } },
    // i32
    .{ .name = "i32", .info = .{ .Integer = .{ .mutable = false, .size = 32, .signed = true, } } },
    // u8
    .{ .name = "u8", .info = .{ .Integer = .{ .mutable = false, .size = 8, .signed = false, } } },
    // i8
    .{ .name = "i8", .info = .{ .Integer = .{ .mutable = false, .size = 8, .signed = true, } } },
    // bool
    .{ .name = "bool", .info = .{ .Bool = false } },
    // flaot
    .{ .name = "float", .info = .{ .Float = false } },
    // void
    .{ .name = "void", .info = .{ .Void = {}, } },
    // type
    .{ .name = "type", .info = .{ .Type = { }, } },
    // any
    .{ .name = "any", .info = .{ .Any = false } },

    // mut u32
    .{ .name = "mut u32", .info = .{ .Integer = .{ .mutable = true, .size = 32, .signed = false, } } },
    // mut i32
    .{ .name = "mut i32", .info = .{ .Integer = .{ .mutable = true, .size = 32, .signed = true, } } },
    // mut u8
    .{ .name = "mut u8", .info = .{ .Integer = .{ .mutable = true, .size = 8, .signed = false, } } },
    // mut i8
    .{ .name = "mut i8", .info = .{ .Integer = .{ .mutable = true, .size = 8, .signed = true, } } },
    // mut bool
    .{ .name = "mut bool", .info = .{ .Bool = true } },
    // mut float
    .{ .name = "mut float", .info = .{ .Float = true } },
    // comptime int
    .{ .name = "comptime_int", .info = .{ .ComptimeInt = { }, } },
    // comptime float
    .{ .name = "comptime_float", .info = .{ .ComptimeFloat = { }, } },
    // string ([]u8)
    .{ .name = "string", .info = .{ .Pointer = .{ .mutable = false, .child = 2, .pointerType = .Slice, }, } },
    // mut any
    .{ .name = "mut any", .info = .{ .Any = true } },
    // entry point
    .{ .name = "entry_point", .info = .{ .Function = .{ .mutable = false, .name = "root::main", .argTypes = &.{}, .returnTypes = &.{ 1 } } } },
};
