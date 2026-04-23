// TODO: Execution stack for error reporting

const std = @import("std");
const common = @import("../core/common.zig");
const defines = @import("../core/defines.zig");
const collections = @import("../util/collections.zig");
const functional = @import("../util/functional.zig");
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

    var typeTable = try TypeTable.init(allocator, typeCount + @as(u32, @intCast(Comptime.builtins.len)));
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
        typeTable.appendAssumeCapacity(std.meta.activeTag(builtin.info), builtin.info);
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

    const mainType = try self.typecheckDecl(self.symbols.lookup.get(.{ .scope = 1, .name = "main" }).?);
    if (
        mainType.len() != 1
        or
        mainType.at(0) != comptime Comptime.Builtin.Type("entry_point").at(0)
    ) {
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
        if (decl.topLevel)
            try self.typecheckValue(try self.executer.eval(decl.node))
        else if (try self.executer.attemptEval(decl.node)) |success|
            try self.typecheckValue(success)
        else
            try self.typecheckExpression(decl.node, varType);

    const expected = self.extra.items[varType.at(0)];
    const got = self.extra.items[initializer.at(0)];

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
    _ = maybeExpected;
    _ = tokens;

    const expr = ast.expressions.get(expressionPtr);
    return switch (expr.type) {
        .Identifier => {
            self.lastToken = expr.value;
            const decl = self.symbols.findDecl(.{ .file = self.currentFile, .expr = expressionPtr });
            return self.typecheckDecl(decl);
        },
        .PointerType => self.expectType(expr.value),
        else => |t| {
            self.report("{s} is not implemented.", .{@tagName(t)});
            return error.NotImplemented;
        }
    };
}

pub fn typecheckValue(_: *const Typechecker, val: Comptime.Value) Error!defines.Range {
    return switch (val) {
        .Int => comptime Comptime.Builtin.Type("comptime_int"),
        .Float => comptime Comptime.Builtin.Type("comptime_float"),
        .String => comptime Comptime.Builtin.Type("string"),
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
    };
}

pub fn typecheckDecl(self: *Typechecker, declPtr: defines.DeclPtr) Error!defines.Range {
    const allocator = self.arena.allocator();

    const ast = self.context.getAST(self.currentFile);
    const tokens = self.context.getTokens(ast.tokens);
    _ = tokens;

    const decl = self.symbols.declarations.get(declPtr);

    const isPresent = self.lookup.getOrPut(allocator, declPtr) catch return error.AllocatorFailure;

    if (isPresent.found_existing) {
        switch (isPresent.value_ptr.status) {
            .Checked => return isPresent.value_ptr.types,
            .InProgress => {
                self.report("Dependency cycle detected.", .{});
                return error.DependencyCycle;
            },
            else => unreachable,
        }
    }

    isPresent.value_ptr.* = .{
        .status = .InProgress,
        .types = std.mem.zeroes(defines.Range),
    };

    if (decl.kind != .Builtin) {
        self.lastToken = decl.token;
    }

    const types = switch (decl.kind) {
        .Builtin =>
                if (Comptime.Builtin.isBuiltinType(decl.node)) comptime Comptime.Builtin.Type("type")
                else {
                    self.report("{s} is not implemented for {s}.", .{@tagName(decl.kind), Comptime.Builtin.TypeName(decl.index)});
                    return error.NotImplemented;
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

    return types;
}

pub fn registerType(self: *Typechecker, newType: TypeInfo) Error!defines.Range {
    const isPresent = self.typeMap.getOrPut(self.arena.allocator(), newType)
        catch return error.AllocatorFailure;

    if (!isPresent.found_existing) {
        const typeID = try self.typeTable.addOne(self.arena.allocator());
        const start: u32 = @intCast(self.extra.items.len);
        self.extra.append(self.arena.allocator(), typeID)
            catch return error.AllocatorFailure;
        isPresent.value_ptr.* = .{
            .start = start,
            .end = start + 1,
        };

        switch (newType) {
            .Struct => self.typeTable.set(typeID, .Struct, newType),
            .Union => self.typeTable.set(typeID, .Union, newType),
            .Enum => self.typeTable.set(typeID, .Enum, newType),
            .Pointer => self.typeTable.set(typeID, .Pointer, newType),
            .Function => self.typeTable.set(typeID, .Function, newType),
            .Array => self.typeTable.set(typeID, .Array, newType),
            else => unreachable,
        }
    }

    return isPresent.value_ptr.*;
}

pub fn report(self: *const Typechecker, comptime fmt: []const u8, args: anytype) void {
    common.log.err(fmt, args);
    const token = self.context.getTokens(self.currentFile).get(self.lastToken);
    const position = token.position(self.context, self.currentFile);
    common.log.err("\t{s} {d}:{d}\n", .{ self.context.getFileName(self.currentFile), position.line, position.column});
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
            self.assertSuitableSingle(this.at(@intCast(i)), that.at(@intCast(i)));
        };
}

pub fn assertSuitableSingle(self: *const Typechecker, this: TypeID, that: TypeID) Error!void {
    const thisType = self.typeTable.tag()[this];
    const thatType = self.typeTable.tag()[that];

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

    const thisType = self.typeTable.tag()[this];
    const thatType = self.typeTable.tag()[that];

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
    return switch (self.typeTable.tag()[typeID]) {
        .Any => self.typeTable.get(.Any, typeID),
        .Bool => self.typeTable.get(.Bool, typeID),
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
        fn typename(this: *const Typechecker, comptime T: std.meta.FieldEnum(TypeInfo), alc: Allocator, tid: TypeID) []const u8 {
            const t = this.typeTable.get(T, tid);
            
            const prefix = if (t.mutable) "" else "mut ";

            const res = alc.alloc(u8, prefix.len + t.name.len) catch return "AllocatorFailure";
            return std.fmt.bufPrint(res, "{s}{s}", .{prefix, t.name}) catch unreachable;
        }
    }.typename;

    return
        if (Comptime.Builtin.isBuiltinType(typeID)) Comptime.Builtin.TypeName(typeID)
        else ret: switch (self.typeTable.tag()[typeID]) {
            .Struct => typename(self, .Struct, allocator, typeID),
            .Union => typename(self, .Union, allocator, typeID),
            .Enum => typename(self, .Enum, allocator, typeID),
            .Function => typename(self, .Function, allocator, typeID),
            .Pointer => {
                const ptr: Types.Pointer = self.typeTable.get(.Pointer, typeID);
                const child = self.typeName(allocator, ptr.child);

                const prefix = switch (ptr.pointerType) {
                    .Slice => "[]",
                    .Single => "*",
                    .C => "[@c]",
                };

                const res = allocator.alloc(u8, child.len + prefix.len) catch break :ret "AllocatorFailure";
                break :ret std.fmt.bufPrint(res, "{s}{s}", .{prefix, child}) catch unreachable;
            },
            .Array => {
                const arr: Types.Array = self.typeTable.get(.Array, typeID);
                const child = self.typeName(allocator, arr.child);

                const prefix = if (arr.mutable) "mut " else "";

                const res = allocator.alloc(u8, child.len + prefix.len) catch break :ret "AllocatorFailure";
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
