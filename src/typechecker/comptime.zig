const std = @import("std");
const common = @import("../core/common.zig");
const defines = @import("../core/defines.zig");
const collections = @import("../util/collections.zig");
const Types = @import("type.zig");

const assert = std.debug.assert;

const Parser = @import("../parser/parser.zig");
const Typechecker = @import("typechecker.zig");
const Resolver = @import("resolver.zig");
const Allocator = std.mem.Allocator;
const Arena = std.heap.ArenaAllocator;
const Error = common.CompilerError;

const Cache = collections.HashMap(Resolver.ResolutionKey, ValuePtr);
const Memory = std.ArrayList(Value);

const ValuePtr = u32;

// TODO: Turn into a manually tagged union
// with possibly flattened fields for performance
// and memory usage
pub const Value = union(enum) {
    Int: u32,
    Float: f32,
    String: []const u8,
    Bool: bool,
    Enum: union(enum) {
        Literal: []const u8,
        Type: struct {
            Type: Types.TypeID,
            Value: u32,
        },
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
        Type: Types.TypeID,
        To: ValuePtr,
    },
    Function: u32, // TODO: Function Ptrs
    Void: void,
    Undefined: Types.TypeID,
};

const Comptime = @This();

cache: Cache,
typechecker: *Typechecker,
arena: Arena,
gpa: Allocator,
attempting: bool,
memory: Memory,

pub fn init(typechecker: *Typechecker, gpa: Allocator) Error!Comptime {
    var arena = Arena.init(gpa);
    const allocator = arena.allocator();

    var cache = Cache.empty;
    cache.ensureTotalCapacity(allocator, typechecker.symbols.resolutionMap.count()) catch return error.AllocatorFailure;

    return .{
        .typechecker = typechecker,
        .gpa = gpa,
        .cache = cache,
        .memory = Memory.initCapacity(allocator, 1024) catch return error.AllocatorFailure,
        .attempting = false,
        .arena = arena,
    };
}

pub fn attemptEval(self: *Comptime, exprPtr: defines.ExpressionPtr, maybeExpected: ?defines.Range) Error!?Value {
    return self.eval(exprPtr, maybeExpected) catch null;
}

pub fn eval(self: *Comptime, exprPtr: defines.ExpressionPtr, maybeExpected: ?defines.Range) Error!Value {
    const typechecker = self.typechecker;
    const file = typechecker.currentFile;
    const ast = typechecker.context.getAST(self.typechecker.currentFile);

    const key = Resolver.ResolutionKey{
        .file = typechecker.currentFile,
        .expr = exprPtr,
    };

    if (self.cache.get(key)) |cached| {
        return self.memory.items[cached];
    }

    const expr = ast.expressions.get(exprPtr);
    const value = switch (expr.type) {
        .Identifier =>
            if (expr.value == 0) Value{ .Type = comptime Builtin.Type("any").at(0) }
            else try self.evalDecl(typechecker.symbols.findDecl(.{ .file = file, .expr = exprPtr }), maybeExpected),
        .Literal => try self.evalLiteral(&expr),
        .PointerType => try self.evalPtrType(&expr),
        .MutableType => try self.evalMutType(&expr),
        .ArrayType => try self.evalArrType(&expr),
        else => {
            self.report("Unable to resolve comptime expression.", .{});
            return error.NotImplemented;
        },
    };

    const ptr = try self.memory.addOne(self.arena.allocator());
    ptr.* = value;
    self.cache.putNoClobber(self.arena.allocator(), key, @intCast(self.memory.items.len - 1))
        catch return error.AllocatorFailure;
    return value;
}

fn evalDecl(self: *Comptime, declPtr: defines.DeclPtr, maybeExpected: ?defines.Range) Error!Value {
    const decls = self.typechecker.symbols.declarations;
    _ = try self.typechecker.typecheckDecl(declPtr, maybeExpected);

    const decl  = decls.get(declPtr);
    return switch (decl.kind) {
        .Builtin => self.evalBuiltin(&decl, maybeExpected),
        .Variable => self.eval(decl.node, maybeExpected),
        else => |t| {
            self.report("{s} declaration is not implemented.", .{@tagName(t)});
            return error.NotImplemented;
        },
    };
}

fn evalBuiltin(self: *Comptime, decl: *const Resolver.Declaration, maybeExpected: ?defines.Range) Error!Value {
    const BI = Resolver.BuiltinIndex;

    return if (Builtin.isBuiltinType(decl.type)) .{
        .Type = decl.type,
    }
    else switch (decl.type) {
        BI("undefined") =>
            if (maybeExpected) |expected| .{ .Undefined = expected.at(0) }
            else {
                self.report("Unable to infer the type of undefined.", .{});
                return error.MissingTypeSpecifier;
            },
        else => {
            self.report("{s} builtin is not implemented.", .{Resolver.builtins[decl.type]});
            return error.NotImplemented;
        },
    };
}

fn evalLiteral(self: *Comptime, expr: *const Parser.Expression) Error!Value {
    const token = self.typechecker.context.getTokens(self.typechecker.currentFile).get(expr.value);
    const lexeme = token.lexeme(self.typechecker.context, self.typechecker.currentFile);
    return switch (token.type) {
        .True, .False => .{ .Bool = token.type == .True },
        .EnumLiteral => .{ .Enum = .{ .Literal = lexeme, }},
        .Float => .{ .Float = std.fmt.parseFloat(f32, lexeme) catch unreachable },
        .Integer => .{ .Int = std.fmt.parseInt(u32, lexeme, 10) catch |err| switch (err) {
            error.Overflow => {
                self.report("Given literal '{s}' is too big for comptime evaluation.", .{lexeme});
                return error.IntegerOverflow;
            },
            else => unreachable,
        }},
        .String => .{ .String = lexeme },
        else => unreachable,
    };
}

fn evalPtrType(self: *Comptime, expr: *const Parser.Expression) Error!Value {
    const inner = try self.expectType(expr.value);

    return .{
        .Type = (try self.typechecker.registerType(.{
            .Pointer = .{
                .pointerType = .Single,
                .mutable = false,
                .child = inner.Type
            },
        })).at(0),
    };
}

fn evalMutType(self: *Comptime, expr: *const Parser.Expression) Error!Value {
    const inner = try self.expectType(expr.value);

    if (self.typechecker.canBeMutable(inner.Type)) {
        const typeInfo = self.typechecker.typeTable.get(inner.Type);
        const typeID = try self.typechecker.registerType(self.typechecker.makeMutable(typeInfo));

        return .{
            .Type = typeID.at(0),
        };
    }
    else {
        self.report("Redundant 'mut' specifier on already mutable type '{s}'.", .{
            self.typechecker.typeName(self.typechecker.arena.allocator(), inner.Type)
        });
        return error.InvalidSpecifier;
    }
}

fn evalArrType(self: *Comptime, expr: *const Parser.Expression) Error!Value {
    const ast = self.typechecker.context.getAST(self.typechecker.currentFile);

    const size = switch (try self.eval(ast.extra[expr.value], null)) {
        .Int => |val| val,
        else => |tag| {
            self.report("Expected a 'comptime_int' value as size specifier. Got '{s}' instead.", .{@tagName(std.meta.activeTag(tag))});
            return error.TypeMismatch;
        },
    };

    const inner = try self.expectType(ast.extra[expr.value + 1]);

    const newType = Types.TypeInfo{
        .Array = .{
            .len = size,
            .mutable = false,
            .child = inner.Type,
        },
    };

    return .{
        .Type = (try self.typechecker.registerType(newType)).at(0),
    };
}

pub fn expectType(self: *Comptime, exprPtr: defines.ExpressionPtr) Error!Value {
    return .{
        .Type = switch (try self.eval(exprPtr, null)) {
            .Type => |t| t,
            else => |otherwise| {
                self.report("Expected a type expression, got '{s}' instead.", .{@tagName(otherwise)});
                return error.UnexpectedNonTypeExpression;
            },
        },
    };
}

fn report(self: *Comptime, comptime fmt: []const u8, args: anytype) void {
    return
        if (self.attempting) {}
        else self.typechecker.report("COMPTIME: " ++ fmt, args);
}

pub fn deinit(self: *Comptime) void {
    self.arena.deinit();
}

pub const Builtin = struct {
    pub fn isBuiltinType(typeID: Types.TypeID) bool {
        return typeID <= comptime Builtin.Type("any").at(0);
    }

    pub fn TypeName(btype: Types.TypeID) []const u8 {
        assert(btype < builtins.len);
        return builtins[btype].name;
    }

    pub fn Type(btype: []const u8) defines.Range {
        comptime {
            var flag = false;
            for (builtins) |item| {
                if (std.mem.eql(u8, item.name, btype)) {
                    flag = true;
                }
            }

            if (!flag)
                @compileError("Unknown type.");
        }

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

pub const builtins = [_]struct {
    name: []const u8,
    info: Types.TypeInfo,
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
    .{ .name = "void", .info = .{ .Void = { }, } },
    // type
    .{ .name = "type", .info = .{ .Type = { }, } },
    // noreturn
    .{ .name = "noreturn", .info = .{ .Noreturn = { }, } },
    // enum literal
    .{ .name = "enum_literal", .info = .{ .EnumLiteral = { } } },
    // comptime int
    .{ .name = "comptime_int", .info = .{ .ComptimeInt = { }, } },
    // comptime float
    .{ .name = "comptime_float", .info = .{ .ComptimeFloat = { }, } },
    // any
    .{ .name = "any", .info = .{ .Any = false } },

    // string ([]u8)
    .{ .name = "string", .info = .{ .Pointer = .{ .mutable = false, .child = 2, .pointerType = .Slice, }, } },
    // mut any
    .{ .name = "mut any", .info = .{ .Any = true } },
    // entry point
    .{ .name = "entry_point", .info = .{ .Function = .{ .mutable = false, .name = "root::main", .argTypes = &.{}, .returnTypes = &.{ 1 } } } },
};
