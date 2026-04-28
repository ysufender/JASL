const std = @import("std");
const common = @import("../core/common.zig");
const defines = @import("../core/defines.zig");
const collections = @import("../util/collections.zig");
const functional = @import("../util/functional.zig");
const Types = @import("type.zig");

const Parser = @import("../parser/parser.zig");
const Comptime = @import("comptime.zig");
const Resolver = @import("resolver.zig");
const ModuleList = @import("../parser/prepass.zig").ModuleList;
const TypeInfo = Types.TypeInfo;
const TypeID = Types.TypeID;
const MultiArrayList = std.MultiArrayList;
const Error = common.CompilerError;
const Context = common.CompilerContext;
const Arena = std.heap.ArenaAllocator;
const Allocator = std.mem.Allocator;
const Callstack = collections.StaticRingStack(defines.DeclPtr, defines.stackLimit);

const BuiltinIndex = Resolver.BuiltinIndex;
const deepCopy = collections.deepCopy;
const assert = std.debug.assert;

pub const TypeTable = MultiArrayList(TypeInfo);
pub const TypeMap = collections.HashMap(TypeInfo, defines.Range);
pub const ResolutionMap = collections.HashMap(defines.DeclPtr, defines.Range);
pub const MetadataMap = collections.HashMap(Element, []const defines.ExpressionPtr);
const LookupMap = collections.HashMap(defines.DeclPtr, TypecheckStatus);

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

    pub const Slice = struct {
        all: List.Slice,
        ints: Integer.Slice,
        floats: Float.Slice,
        strings: String.Slice,
        bools: Bool.Slice,
        aggs: Aggregate.Slice,
    };

    all: List,
    ints: Integer,
    floats: Float,
    strings: String,
    bools: Bool,
    aggs: Aggregate,

    pub fn slice(self: *const Constants) Slice {
        return .{
            .all = self.all.slice(),
            .ints = self.ints.items,
            .floats = self.floats.items,
            .strings = self.strings.items,
            .bools = self.bools.items,
            .aggs = self.aggs.items,
        };
    }
};

pub const Resolution = struct {
    types: TypeTable.Slice,
    resolutionMap: ResolutionMap,
    extra: std.ArrayList(TypeID).Slice,
    constants: Constants.Slice,

    pub fn get(self: *const Resolution, key: defines.DeclPtr) defines.Range {
        return self.resolutionMap.get(key).?;
    }

    pub fn getTypeAt(self: *const Resolution, key: defines.DeclPtr, index: u32) TypeID {
        return self.extra[self.resolutionMap.get(key).?.at(index)];
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
callstack: Callstack,

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
    const typeCount = counts.types * 3 + @as(u32, @intCast(Comptime.builtins.len));

    var typeTable = TypeTable{};
    typeTable.ensureTotalCapacity(allocator, typeCount + @as(u32, @intCast(Comptime.builtins.len)))
        catch return error.AllocatorFailure;
    var extra = std.ArrayList(TypeID).initCapacity(allocator, typeCount) catch return error.AllocatorFailure;
    var reso = ResolutionMap.empty;
    var typeMap = TypeMap.empty;
    var metadata = MetadataMap.empty;
    var lookup = LookupMap.empty;

    reso.ensureTotalCapacity(allocator, symbolTable.declarations.len) catch return error.AllocatorFailure;
    typeMap.ensureTotalCapacity(allocator, typeCount + @as(u32, @intCast(Comptime.builtins.len))) catch return error.AllocatorFailure;
    lookup.ensureTotalCapacity(allocator, symbolTable.declarations.len) catch return error.AllocatorFailure;
    metadata.ensureTotalCapacity(allocator, counts.meta * 3) catch return error.AllocatorFailure;

    inline for (Comptime.builtins, 0..) |builtin, id| {
        typeTable.appendAssumeCapacity(builtin.info);
        typeMap.putAssumeCapacityNoClobber(builtin.info, .{
            .start = @intCast(id),
            .end = @intCast(id + 1)
        });
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
        .callstack = .{},
        .arena = arena,
    };
}

pub fn typecheck(self: *Typechecker, allocator: Allocator) Error!Resolution {
    self.currentFile = self.modules.getItem("root", .dataIndex);
    
    if (!self.modules.getItem("root", .symbolPtrs).contains("main")) {
        self.report("Couldn't find an entry point in the root module.", .{});
        return error.MissingEntry;
    }

    defer self.arena.deinit();
    self.executer = try Comptime.init(self, allocator);

    const mainPtr = self.symbols.lookup.get(.{ .scope = 1, .name = "main" }).?;
    const mainType = try self.typecheckDecl(mainPtr, null);
    if (
        mainType.len() != 1
        or
        mainType.at(0) != comptime Comptime.Builtin.Type("entry_point").at(0)
    ) {
        const main = self.symbols.getDecl(mainPtr);
        self.lastToken = main.token;
        self.report("Unexpected type of entry point 'main'. Expected '*fn void -> i32', received '{s}'", .{
            self.typeNameMany(allocator, mainType),
        });
        return error.TypeMismatch;
    }

    return collections.deepCopy(Resolution{
        .types = self.typeTable.slice(), 
        .resolutionMap = self.reso,
        .constants = self.constants.slice(),
        .extra = self.extra.items,
    }, allocator);
}

pub fn typecheckVariable(self: *Typechecker, decl: *const Resolver.Declaration) Error!defines.Range {
    const varType = try self.expectType(decl.type);
    const initializer =
        if (
            decl.topLevel or
            varType.at(0) == comptime Comptime.Builtin.Type("type").at(0)
        )
            try self.typecheckValue(try self.executer.eval(decl.node, varType))
        else
            try self.typecheckExpression(decl.node, varType);

    if (initializer.len() != decl.meta) {
        self.report(
            "Mismatching initializer counts in variable definition."
            ++ " Expected '{d}', received '{d}'", .{decl.meta, initializer.len()}
        );
        return error.TypeMismatch;
    }

    const expected = self.extra.items[varType.at(0)];
    const got = self.extra.items[initializer.at(decl.index)];

    // TODO: type renaming on binding
    return
        if (self.suitableSingle(expected, got))
            self.infer(expected, got)
        else  {
            self.report(
                "Mismatching initializer type in variable definition."
                ++ " Expected '{s}', received '{s}'.", .{
                self.typeName(self.arena.allocator(), expected),
                self.typeName(self.arena.allocator(), got),
            });
            return error.TypeMismatch;
        };
}

pub fn typecheckExpression(self: *Typechecker, expressionPtr: defines.ExpressionPtr, maybeExpected: ?defines.Range) Error!defines.Range {
    const ast = self.context.getAST(self.currentFile);
    const tokens = self.context.getTokens(ast.tokens);
    _ = tokens;

    if (self.executer.attemptEval(expressionPtr, maybeExpected)) |result| {
        return self.typecheckValue(result);
    }

    const expr = ast.expressions.get(expressionPtr);
    return switch (expr.type) {
        .Identifier => {
            self.lastToken = expr.value;
            const decl = self.symbols.findDecl(.{ .file = self.currentFile, .expr = expressionPtr });
            return self.typecheckDecl(decl, maybeExpected);
        },
        .Indexing => self.typecheckIndexing(expr.value),
        else => |t| {
            self.report("Unable to typecheck expression '{s}'.", .{@tagName(t)});
            return error.TypecheckingFailure;
        }
    };
}

pub fn typecheckValue(_: *const Typechecker, val: Comptime.Value) Error!defines.Range {
    return switch (val) {
        .Int => comptime Comptime.Builtin.Type("comptime_int"),
        .Float => comptime Comptime.Builtin.Type("comptime_float"),
        .Bool => comptime Comptime.Builtin.Type("bool"),
        .Enum => |enumeration| switch (enumeration) {
            .Literal => comptime Comptime.Builtin.Type("enum_literal"),
            .Type => |enumType| .{
                .start = enumType.Type,
                .end = enumType.Type + 1,
            },
        },
        .Union => |uni| .{
            .start = uni.Type,
            .end = uni.Type + 1,
        },
        .Struct => |str| .{
            .start = str.Type,
            .end = str.Type + 1,
        },
        .Type => comptime Comptime.Builtin.Type("type"),
        .Pointer => |ptr| .{
            .start = ptr.Type,
            .end = ptr.Type + 1,
        },
        .Function => |func| .{
            .start = func,
            .end = func + 1,
        },
        .Void => comptime Comptime.Builtin.Type("void"),
        .Undefined => |undef| .{
            .start = undef,
            .end = undef + 1,
        },
        .Slice => |slice| .{
            .start = slice.Type,
            .end = slice.Type + 1,
        },
    };
}

pub fn typecheckIndexing(self: *Typechecker, extraPtr: defines.OpaquePtr) Error!defines.Range {
    _ = self;
    _ = extraPtr;
    return error.NotImplemented;
}

pub fn typecheckCasting(self: *Typechecker, extraPtr: defines.OpaquePtr, maybeExpected: ?defines.Range) Error!defines.Range {
    _ = self;
    _ = extraPtr;
    _ = maybeExpected;
    return error.NotImplemented;
}

pub fn typecheckDecl(self: *Typechecker, declPtr: defines.DeclPtr, maybeExpected: ?defines.Range) Error!defines.Range {
    const allocator = self.arena.allocator();

    const ast = self.context.getAST(self.currentFile);
    const tokens = self.context.getTokens(ast.tokens);

    const decl = self.symbols.declarations.get(declPtr);

    const isPresent = self.lookup.getOrPut(allocator, declPtr) catch return error.AllocatorFailure;

    if (isPresent.found_existing) {
        switch (isPresent.value_ptr.status) {
            .Checked => return isPresent.value_ptr.types,
            .InProgress => {
                if (!self.executer.flags.isSet(Comptime.Flags.flag(.CanCycle))) {
                    self.report("Dependency cycle detected. '{s}' depends on itself.", .{
                        tokens.get(decl.token).lexeme(self.context, self.currentFile),
                    });
                }
                return error.DependencyCycle;
            },
            else => unreachable,
        }
    }

    isPresent.value_ptr.* = .{
        .status = .InProgress,
        .types = std.mem.zeroes(defines.Range),
    };

    const prev = self.lastToken;
    if (decl.kind != .Builtin) {
        self.lastToken = decl.token;
    }
    defer self.lastToken = prev;

    self.callstack.push(declPtr);

    const types = switch (decl.kind) {
        .Builtin =>
            if (Comptime.Builtin.isBuiltinType(decl.type)) comptime Comptime.Builtin.Type("type")
            else switch (decl.type) {
                BuiltinIndex("undefined") =>
                    if (maybeExpected) |expected| expected
                    else {
                        self.report("Unable to resolve the type of undefined value.", .{});
                        return error.MissingTypeSpecifier;
                    },
                else => {
                    self.report("Builtin '{s}' is not implemented.", .{Resolver.builtins[decl.type]});
                    return error.NotImplemented;
                },
            },
        .Variable => try self.typecheckVariable(&decl),
        else => {
            self.report("{s} is not implemented.", .{@tagName(decl.kind)});
            return error.NotImplemented;
        },
    };

    isPresent.value_ptr.* = .{
        .status = .Checked,
        .types = types,
    };

    _ = self.callstack.pop();
    return types;
}

pub fn registerType(self: *Typechecker, newType: TypeInfo) Error!defines.Range {
    const isPresent = self.typeMap.getOrPut(self.arena.allocator(), newType)
        catch return error.AllocatorFailure;

    if (!isPresent.found_existing) {
        const typeID = try self.typeTable.addOne(self.arena.allocator());
        const start: u32 = @intCast(self.extra.items.len);
        self.extra.append(self.arena.allocator(), @intCast(typeID))
            catch return error.AllocatorFailure;
        isPresent.value_ptr.* = .{
            .start = start,
            .end = start + 1,
        };

        self.typeTable.set(typeID, newType);
    }

    return isPresent.value_ptr.*;
}

pub fn report(self: *Typechecker, comptime fmt: []const u8, args: anytype) void {
    common.log.err(fmt, args);
    const token = self.context.getTokens(self.currentFile).get(self.lastToken);
    const position = token.position(self.context, self.currentFile);
    common.log.err(("." ** 4) ++ " In {s} {d}:{d}{s}", .{
        self.context.getFileName(self.currentFile),
        position.line,
        position.column,
        if (self.callstack.empty()) "\n" else ""
    });
    self.dumpCallStack();
}

fn dumpCallStack(self: *Typechecker) void {
    _ = self.callstack.pop();
    while (self.callstack.pop()) |declPtr| {
        const lastDecl = self.symbols.getDecl(declPtr);
        const modulePtr = self.symbols.scopes.get(lastDecl.scope).module;
        const module = self.modules.modules.get(modulePtr);
        const token = self.context.getTokens(module.dataIndex).get(lastDecl.token);
        const position = token.position(self.context, module.dataIndex);
        common.log.err(("." ** 8) ++ " Required from '{s} {d}:{d}'{s}", .{
            self.context.getFileName(module.dataIndex),
            position.line,
            position.column,
            if (self.callstack.empty()) "\n" else ""
        });
    }
}

pub fn assertCastable(self: *Typechecker, from: TypeID, to: TypeID) Error!void {
    const fmax = std.math.floatMax;
    const fmin = struct{fn fmin(comptime T: type) T { return -fmax(T); }}.fmin;

    const fromType = self.typeTable.get(from);
    const toType = self.typeTable.get(to);

    if (from == to) {
        self.report("Unnecessary cast from type '{s}' to itself.", .{
            self.typeName(self.arena.allocator(), from),
        });
        return error.RedundantCast;
    }

    switch (to) {
        Comptime.Builtin.Type("any").at(0),
        Comptime.Builtin.Type("mut any").at(0) => return error.InferenceError,
        else => { },
    }

    if (!self.mutable(from) and self.mutable(to)) {
        return error.MutabilityViolation;
    }

    switch (fromType) {
        .Enum, .Union, .Struct => try self.assertStructurallyIdentical(from, to),
        .Bool => switch (toType) {
            .Integer => |int| try functional.throwIf(int.size <= 0, error.SizeMismatch),
            else => return error.IncompatibleTypes,
        },
        .Integer => |fromInt| switch (toType) {
            .Integer => |toInt| try functional.throwIf(!toInt.canContain(fromInt), error.SizeMismatch),
            .Float => try functional.throwIf(
                fmax(f32) < @as(f32, @floatFromInt(fromInt.range().max))
                or fmin(f32) > @as(f32, @floatFromInt(fromInt.range().min)),
                error.SizeMismatch,
            ),
            else => return error.IncompatibleTypes,
        },
        .Float => switch (toType) {
            .Integer => |toInt| try functional.throwIf(
                fmax(f32) > @as(f32, @floatFromInt(toInt.range().max))
                or fmin(f32) < @as(f32, @floatFromInt(toInt.range().min)),
                error.SizeMismatch,
            ),
            else => return error.IncompatibleTypes,
        },
        .Pointer => |fromPtr| switch (toType) {
            .Pointer => |toPtr| try self.assertCastablePtr(fromPtr, toPtr),
            else => return error.IncompatibleTypes,
        },
        .Function => switch (toType) {
            .Function => { },
            else => return error.IncompatibleTypes,
        },
        .Any, .Type, .ComptimeFloat,
        .ComptimeInt, .EnumLiteral,
        .Noreturn, .Array, .Void => return error.IncompatibleTypes,
    }
}

pub fn castable(self: *Typechecker, from: TypeID, to: TypeID) bool {
    self.assertCastable(from, to) catch return false;
    return true;
}

pub fn assertCastablePtr(self: *const Typechecker, this: Types.Pointer, that: Types.Pointer) Error!void {
    switch (this.size) {
        .Slice => try functional.throwIf(that.size == .Slice and self.sizeOf(this.child) != self.sizeOf(that.child), error.MismatchingSliceChildType),
        .Single => try functional.throwIf(that.size == .Slice, error.PointerSizeMismatch),
        .C => try functional.throwIf(that.size == .Slice, error.PointerSizeMismatch),
    }

    try functional.throwIf(!self.mutable(this.child) and self.mutable(that.child), error.MutabilityViolation);
}

/// Does no mutability check
pub fn assertStructurallyIdentical(self: *const Typechecker, this: TypeID, that: TypeID) Error!void {
    const fromType = self.typeTable.get(this);
    const toType = self.typeTable.get(that);

    if (std.meta.activeTag(fromType) != std.meta.activeTag(toType)) {
        return error.IncompatibleTypes;
    }

    switch (fromType) {
        .Struct => |fromStruct| {
            if (fromStruct.fields.len != toType.Struct.fields.len) {
                return error.StructuralMismatch;
            }

            for (fromStruct.fields, toType.Struct.fields) |fromField, toField| {
                if (!fromField.eql(toField)) {
                    return error.StructuralMismatch;
                }
            }
        },
        .Union => |fromUnion| {
            const toUnion = toType.Union;
            if (std.meta.activeTag(fromUnion) != std.meta.activeTag(toUnion)) {
                return error.StructuralMismatch;
            }

            switch (fromUnion) {
                .Tagged => |fromTagged| {
                    const toTagged = toUnion.Tagged;

                    if (fromTagged.fields.len != toTagged.fields.len) {
                        return error.StructuralMismatch;
                    }

                    for (fromTagged.fields, toTagged.fields) |fromField, toField| {
                        if (!fromField.eql(toField)) {
                            return error.StructuralMismatch;
                        }
                    }
                },
                .Plain => |fromPlain| {
                    const toPlain = toUnion.Plain;

                    if (fromPlain.fields.len != toPlain.fields.len) {
                        return error.StructuralMismatch;
                    }

                    for (fromPlain.fields, toPlain.fields) |fromField, toField| {
                        if (!fromField.eql(toField)) {
                            return error.StructuralMismatch;
                        }
                    }
                }
            }
        },
        .Enum => |fromEnum| {
            const toEnum = toType.Enum;

            if (fromEnum.fields.len != toEnum.fields.len) {
                return error.StructuralMismatch;
            }

            for (fromEnum.fields, toEnum.fields) |fromField, toField| {
                if (!std.mem.eql(u8, fromField, toField)) {
                    return error.StructuralMismatch;
                }
            }
        },
        else => return error.ShouldBeImpossible,
    }
}

pub fn structurallyIdentical(self: *const Typechecker, this: TypeID, that: TypeID) bool {
    self.assertStructurallyIdentical(this, that) catch return false;
    return true;
}

pub fn suitable(self: *const Typechecker, expected: defines.Range, got: defines.Range) bool {
    self.assertSuitable(expected, got) catch return false;
    return true;
}

pub fn suitableSingle(self: *const Typechecker, expected: TypeID, got: TypeID) bool {
    self.assertSuitableSingle(expected, got) catch return false;
    return true;
}

pub fn assertSuitable(self: *const Typechecker, this: defines.Range, that: defines.Range) Error!void {
    return
        if (this.len() != that.len()) error.TypeMismatch 
        else for (0..this.len()) |i| {
            try self.assertSuitableSingle(this.at(@intCast(i)), that.at(@intCast(i)));
        };
}

pub fn assertSuitableSingle(self: *const Typechecker, this: TypeID, that: TypeID) Error!void {
    const thisType = std.meta.activeTag(self.typeTable.get(this));
    const thatType = std.meta.activeTag(self.typeTable.get(that));

    return switch (thatType) {
        .Noreturn => { },
        .Any => functional.throwIf(thisType == .Any, error.TypeMismatch),
        else => switch (thisType) {
            .Any => { },
            else => functional.throwIf(thisType != thatType, error.TypeMismatch),
        },
    };
}

pub fn assignable(self: *const Typechecker, this: TypeID, that: TypeID) bool {
    return
        if (!self.mutable(this)) false
        else self.suitableSingle(this, that);
}

pub fn infer(self: *const Typechecker, this: TypeID, that: TypeID) Error!defines.Range {
    try self.assertSuitableSingle(this, that);

    const thisType = std.meta.activeTag(self.typeTable.get(this));
    const thatType = std.meta.activeTag(self.typeTable.get(that));

    const resType = switch (thatType) {
        .Noreturn => that,
        else => switch (thisType) {
            .Any => that,
            else => this,
        },
    };

    return .{
        .start = resType,
        .end = resType + 1,
    };
}

pub fn expectType(self: *Typechecker, exprPtr: defines.ExpressionPtr) Error!defines.Range {
    return
        if (self.executer.expectType(exprPtr)) |val| .{
            .start = val.Type,
            .end = val.Type + 1,
        } 
        else |err| err;
}

pub fn mutable(self: *const Typechecker, typeID: TypeID) bool {
    return switch (self.typeTable.get(typeID)) {
        .Any => |any| any,
        .Bool => |b| b,
        .Float => |fl| fl,
        .Struct => |str| str.mutable,
        .Union => |uni| switch (uni) {
            .Tagged => |tagged| tagged.mutable,
            .Plain => |plain| plain.mutable,
        },
        .Enum => |enu| enu.mutable,
        .Integer => |int| int.mutable,
        .Pointer => |ptr| ptr.mutable,
        .Array => |arr| arr.mutable,
        .Function => |func| func.mutable,
        else => false,
    };
}

pub fn canBeMutable(self: *const Typechecker, typeID: TypeID) bool {
    return switch (self.typeTable.get(typeID)) {
        .Any, .Bool, .Float,
        .Struct, .Union, .Enum,
        .Integer, .Pointer, .Array,
        .Function => !self.mutable(typeID),
        else => false,
    };
}

pub fn makeMutable(_: *const Typechecker, info: TypeInfo) TypeInfo {
    return switch (info) {
        .Any => .{ .Any = true },
        .Bool => .{ .Bool = true },
        .Float => .{ .Float = true },
        .Struct => |str| .{
            .Struct = .{
                .mutable = true,
                .name = str.name,
                .fields = str.fields,
                .definitions = str.definitions,
            },
        },
        .Union => |uni| switch (uni) {
            .Tagged => |tagged| .{
                .Union = .{
                    .Tagged = .{
                        .mutable = true,
                        .tag = tagged.tag,
                        .name = tagged.name,
                        .fields = tagged.fields,
                        .definitions = tagged.definitions,
                    },
                },
            },
            .Plain => |plain| .{
                .Union = .{
                    .Plain = .{
                        .mutable = true,
                        .name = plain.name,
                        .fields = plain.fields,
                        .definitions = plain.definitions,
                    },
                },
            },
        },
        .Enum => |enu| .{
            .Enum = .{
                .mutable = true,
                .name = enu.name,
                .fields = enu.fields,
                .definitions = enu.definitions,
            },
        },
        .Pointer => |ptr| .{
            .Pointer = .{
                .mutable = true,
                .child = ptr.child,
                .size = ptr.size,
            }
        },
        .Array => |arr| .{
            .Array = .{
                .mutable = true,
                .child = arr.child,
                .len = arr.len,
            },
        },
        .Function => |func| .{
            .Function = .{
                .mutable = true,
                .argTypes = func.argTypes,
                .returnTypes = func.returnTypes,
            },
        },
        .Integer => |int| .{
            .Integer = .{
                .mutable = true,
                .size = int.size,
                .signed = int.signed,
            },
        },
        else => unreachable,
    };
}

/// In bytes
pub fn sizeOf(self: *const Typechecker, of: TypeID) u32 {
    return ret: switch (self.typeTable.get(of)) {
        .Pointer => @sizeOf(*void),
        .Function => @sizeOf(@TypeOf(&sizeOf)),
        .Enum => @sizeOf(u32),
        .Float, .ComptimeFloat => @sizeOf(f32),
        .Integer => |int| int.size,
        .Bool => @sizeOf(bool),
        .Void, .Noreturn, .EnumLiteral, .Type, .Any => 0,
        .Array => |arr| arr.len * self.sizeOf(arr.child),
        .ComptimeInt => @sizeOf(i64),
        .Struct => |str| {
            var size: u32 = 0;
            for (str.fields) |field| {
                size += self.sizeOf(field.valueType);
            }

            return size;
        },
        .Union => |uni| {
            const fields = switch (uni) {
                .Tagged => |t| t.fields,
                .Plain => |p| p.fields,
            };
            var size: u32 = 0;
            for (fields) |field| {
                size = @max(size, self.sizeOf(field.valueType));
            }

            break :ret switch (uni) {
                .Tagged => size + @sizeOf(u32),
                .Plain => size,
            };
        },
    };
}

pub fn typeNameMany(self: *const Typechecker, allocator: Allocator, types: defines.Range) []const u8 {
    return ret: switch (types.len()) {
        0 => "void",
        1 => self.typeName(allocator, self.extra.items[types.start]),
        else => {
            const res = allocator.alloc(u8, 64) catch break :ret "AllocatorFailure";
            _ = std.fmt.bufPrint(res, "(", .{}) catch unreachable;
            for (types.start..types.end) |typePtr| {
                _ = std.fmt.bufPrint(res, "{s}{s}", .{
                    self.typeName(allocator, self.extra.items[typePtr]),
                    if (typePtr == types.end - 1) ")" else ", "
                }) catch "TypeNameTooLong";
            }

            break :ret res;
        },
    };
}

pub fn typeName(self: *const Typechecker, allocator: Allocator, typeID: TypeID) []const u8 {
    const typename = struct {
        fn typename(this: *const Typechecker, alc: Allocator, tid: TypeID) []const u8 {
            const prefix = if (this.mutable(tid)) "mut " else "";

            const name = switch (this.typeTable.get(tid)) {
                .Struct => |str| str.name,
                .Union => |uni| switch (uni) {
                    .Tagged => |tagged| tagged.name,
                    .Plain => |plain| plain.name,
                },
                .Enum => |enu| enu.name,
                else => unreachable,
            };

            const res = alc.alloc(u8, prefix.len + name.len) catch return "AllocatorFailure";
            return std.fmt.bufPrint(res, "{s}{s}", .{prefix, name}) catch unreachable;
        }
    }.typename;

    return
        if (Comptime.Builtin.isBuiltinType(typeID)) Comptime.Builtin.TypeName(typeID)
        else ret: switch (self.typeTable.get(typeID)) {
            .Pointer => {
                const ptr: Types.Pointer = self.typeTable.get(typeID).Pointer;
                const child = self.typeName(allocator, ptr.child);

                const mut = if (ptr.mutable) "mut " else "";
                const prefix = switch (ptr.size) {
                    .Slice => "[]",
                    .Single => "*",
                    .C => "[@c]",
                };

                const res = allocator.alloc(u8, child.len + prefix.len + mut.len) catch break :ret "AllocatorFailure";
                break :ret std.fmt.bufPrint(res, "{s}{s}{s}", .{mut, prefix, child}) catch unreachable;
            },
            .Array => {
                const arr: Types.Array = self.typeTable.get(typeID).Array;
                const child = self.typeName(allocator, arr.child);

                const prefix = if (arr.mutable) "mut " else "";
                const size = std.fmt.allocPrint(allocator, "[{d}]", .{arr.len})
                    catch return "AllocatorFailure";

                const res = allocator.alloc(u8, child.len + prefix.len + size.len) catch break :ret "AllocatorFailure";
                break :ret std.fmt.bufPrint(res, "{s}{s}{s}", .{prefix, size, child}) catch unreachable;
            },
            .Struct, .Union, .Enum => typename(self, allocator, typeID),
            .Function => |func| {
                var res: []const u8 = if (func.mutable) "mut *fn (" else "*fn (";

                for (func.argTypes, 0..) |argTypeID, i| {
                    res = std.fmt.allocPrint(allocator, "{s}{s}{s}", .{
                        res,
                        self.typeName(allocator, argTypeID),
                        if (i == func.argTypes.len - 1) ")" else ", ",
                    }) catch return "AllocatorFailure";
                }

                res = std.fmt.allocPrint(allocator, "{s} -> {s}", .{
                    res,
                    if (func.returnTypes.len == 1) "" else "("
                }) catch return "AllocatorFailure";

                for (func.returnTypes, 0..) |retTypeID, i| {
                    res = std.fmt.allocPrint(allocator, "{s}{s}{s}", .{
                        res,
                        self.typeName(allocator, retTypeID),
                        if (func.returnTypes.len == 1) ""
                        else if (i == func.returnTypes.len - 1) ")"
                        else ", "
                    }) catch return "AllocatorFailure";
                }

                break :ret res;
            },
            .EnumLiteral => "enum_literal",
            .ComptimeFloat => "comptime_float",
            .ComptimeInt => "comptime_int",
            .Type => "type",
            .Any => "any",
            .Bool => "bool",
            .Float => "float",
            .Noreturn => "noreturn",
            .Void => "void",
            .Integer => |int| {
                const mut = if (int.mutable) "mut " else "";
                const sign = if (int.signed) "i" else "u"; 
                const size = std.fmt.allocPrint(
                    allocator,
                    "{d}",
                    .{int.size},
                ) catch "AllocatorFailure";

                const res = allocator.alloc(u8, sign.len + size.len + mut.len) catch return "AllocatorFailure";
                break :ret std.fmt.bufPrint(res, "{s}{s}{s}", .{mut, sign, size}) catch unreachable;
            },
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
