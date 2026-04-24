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
    Slice: struct {
        const Self = @This();

        Size: u32,
        To: ValuePtr,

        pub fn at(self: *const Self, index: u32) ValuePtr {
            assert(index < self.Size);
            return self.To + index;
        }
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
rng: std.Random.DefaultPrng,

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
        .rng = .init(5315),
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
        .PointerType => try self.evalPtrType(.Single, &expr),
        .MutableType => try self.evalMutType(&expr),
        .ArrayType => try self.evalArrType(&expr),
        .SliceType => try self.evalPtrType(.Slice, &expr),
        .CPointerType => try self.evalPtrType(.C, &expr),
        .FunctionType => try self.evalFuncType(&expr),
        .EnumDefinition => try self.evalEnumType(&expr),
        .StructDefinition => try self.evalStructType(&expr),
        .UnionDefinition => try self.evalUnionType(&expr),
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
            if (maybeExpected) |expected|
                if (self.typechecker.suitable(expected, comptime Builtin.Type("any")))
                    self.constructUndefined(expected.at(0))
                else  {
                    self.report("Unable to infer the type of undefined value.", .{});
                    return error.MissingTypeSpecifier;
                }
            else {
                self.report("Unable to infer the type of undefined value.", .{});
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

fn evalPtrType(
    self: *Comptime,
    comptime ptrType: @FieldType(Types.Pointer, "size"),
    expr: *const Parser.Expression) Error!Value {
    const ast = self.typechecker.context.getAST(self.typechecker.currentFile);

    const inner = try self.expectType(ast.extra[expr.value + 1]);

    const newType = Types.TypeInfo{
        .Pointer = .{
            .size = ptrType,
            .mutable = false,
            .child = inner.Type,
        },
    };

    return .{
        .Type = (try self.typechecker.registerType(newType)).at(0),
    };
}

fn evalFuncType(self: *Comptime, expr: *const Parser.Expression) Error!Value {
    const allocator = self.arena.allocator();
    const ast = self.typechecker.context.getAST(self.typechecker.currentFile);

    const args = try self.eval(ast.extra[expr.value], null);
    const argSize = ret: switch (args) {
        .Slice => |slice| {
            for (0..slice.Size) |index| {
                switch (self.memory.items[slice.at(@intCast(index))]) {
                    .Type => { },
                    else => |t|{
                        self.report("Expected a type expression, got '{s}' instead.", .{
                            @tagName(std.meta.activeTag(t)),
                        });
                    },
                }
            }

            break :ret slice.Size;
        },
        .Type => 1,
        else => |t| {
            self.report(
                "Expected an argument type list in function type expression,"
                ++ " got '{s}' instead.", .{@tagName(std.meta.activeTag(t))});
            return error.TypeMismatch;
        },
    };

    const returns = try self.eval(ast.extra[expr.value + 1], null);
    const retSize = ret: switch (returns) {
        .Slice => |slice| {
            for (0..slice.Size) |index| {
                switch (self.memory.items[slice.at(@intCast(index))]) {
                    .Type => { },
                    else => |t|{
                        self.report("Expected a type expression, got '{s}' instead.", .{
                            @tagName(std.meta.activeTag(t)),
                        });
                    },
                }
            }

            break :ret slice.Size;
        },
        .Type => 1,
        else => |t| {
            self.report(
                "Expected a return type list in function type expression,"
                ++ " got '{s}' instead.", .{@tagName(std.meta.activeTag(t))});
            return error.TypeMismatch;
        },
    };

    var argTypes = allocator.alloc(Types.TypeID, argSize) catch return error.AllocatorFailure;
    var returnTypes = allocator.alloc(Types.TypeID, retSize) catch return error.AllocatorFailure;

    switch (args) {
        .Type => |argType| argTypes[0] = argType,
        .Slice => |slice| {
            for (0..slice.Size) |index| {
                argTypes[index] = self.memory.items[slice.at(@intCast(index))].Type;
            }
        },
        else => unreachable,
    }

    switch (returns) {
        .Type => |returnType| returnTypes[0] = returnType,
        .Slice => |slice| {
            for (0..slice.Size) |index| {
                returnTypes[index] = self.memory.items[slice.at(@intCast(index))].Type;
            }
        },
        else => unreachable,
    }

    const typeID = try self.typechecker.registerType(.{
        .Function = .{
            .mutable = false,
            .argTypes = argTypes,
            .returnTypes = returnTypes,
        },
    });

    return .{
        .Type = typeID.at(0),
    };
}

fn evalEnumType(self: *Comptime, expr: *const Parser.Expression) Error!Value {
    const allocator = self.arena.allocator();
    const ast = self.typechecker.context.getAST(self.typechecker.currentFile);
    const tokens = self.typechecker.context.getTokens(ast.tokens);

    const fieldRange = defines.Range{
        .start = ast.extra[expr.value],
        .end = ast.extra[expr.value + 1],
    };

    const defRange = defines.Range{
        .start = ast.extra[expr.value + 2],
        .end = ast.extra[expr.value + 3],
    };

    var fields = allocator.alloc([]const u8, fieldRange.len()) catch return error.AllocatorFailure;
    var defs = allocator.alloc(Types.FieldInfo, defRange.len()) catch return error.AllocatorFailure;
    _ = &defs;

    for (0..fieldRange.len()) |index| {
        const token = tokens.get(ast.extra[fieldRange.at(@intCast(index))]);
        const lexeme = token.lexeme(self.typechecker.context, self.typechecker.currentFile);
        fields[index] = lexeme;
    }

    for (0..defRange.len()) |index| {
        const declPtr = self.typechecker.symbols.findDecl(.{
            .file = self.typechecker.currentFile,
            .expr = ast.extra[defRange.at(@intCast(index))],
        });
        const decl = self.typechecker.symbols.getDecl(declPtr);

        // TODO: Should I typecheck decls here?
        const declToken = tokens.get(decl.token);
        const declName = declToken.lexeme(self.typechecker.context, self.typechecker.currentFile);

        defs[index] = Types.FieldInfo{
            .public = decl.public,
            .name = declName,
            // TODO: mark incomplete for now
            .valueType = comptime Builtin.Type("incomplete").at(0),
        };
    }

    const newType = Types.TypeInfo{
        .Enum = .{
            .mutable = false,
            .name = try self.generateRandomName(.Enum),
            .fields = fields,
            .definitions = defs,
        },
    };

    const typeID = try self.typechecker.registerType(newType);
    return .{ .Type = typeID.at(0) };
}

fn evalStructType(self: *Comptime, expr: *const Parser.Expression) Error!Value {
    const allocator = self.arena.allocator();
    const ast = self.typechecker.context.getAST(self.typechecker.currentFile);
    const tokens = self.typechecker.context.getTokens(ast.tokens);

    const fieldRange = defines.Range{
        .start = ast.extra[expr.value],
        .end = ast.extra[expr.value + 1],
    };

    const defRange = defines.Range{
        .start = ast.extra[expr.value + 2],
        .end = ast.extra[expr.value + 3],
    };

    var fields = allocator.alloc(Types.FieldInfo, fieldRange.len()) catch return error.AllocatorFailure;
    var defs = allocator.alloc(Types.FieldInfo, defRange.len()) catch return error.AllocatorFailure;
    _ = &defs;

    for (0..fieldRange.len()) |index| {
        const symbol = ast.signatures.get(ast.extra[fieldRange.at(@intCast(index))]);

        const symbolToken = tokens.get(symbol.name);
        const symbolName = symbolToken.lexeme(self.typechecker.context, self.typechecker.currentFile);

        fields[index] = Types.FieldInfo{
            .public = symbol.public,
            .name = symbolName,
            .valueType = (try self.typechecker.expectType(symbol.type)).at(0),
        };
    }

    for (0..defRange.len()) |index| {
        const declPtr = self.typechecker.symbols.findDecl(.{
            .file = self.typechecker.currentFile,
            .expr = ast.extra[defRange.at(@intCast(index))],
        });
        const decl = self.typechecker.symbols.getDecl(declPtr);

        // TODO: Should I typecheck decls here?
        const declToken = tokens.get(decl.token);
        const declName = declToken.lexeme(self.typechecker.context, self.typechecker.currentFile);

        defs[index] = Types.FieldInfo{
            .public = decl.public,
            .name = declName,
            // TODO: mark incomplete for now
            .valueType = comptime Builtin.Type("incomplete").at(0),
        };
    }

    const newType = Types.TypeInfo{
        .Struct = .{
            .mutable = false,
            .name = try self.generateRandomName(.Struct),
            .fields = fields,
            .definitions = defs,
        },
    };

    const typeID = try self.typechecker.registerType(newType);
    return .{ .Type = typeID.at(0) };
}

fn evalUnionType(self: *Comptime, expr: *const Parser.Expression) Error!Value {
    const allocator = self.arena.allocator();
    const ast = self.typechecker.context.getAST(self.typechecker.currentFile);
    const tokens = self.typechecker.context.getTokens(ast.tokens);

    const tagged = ast.extra[expr.value] == 1;
    const offset: u32 = if (tagged) 2 else 1;

    const fieldRange = defines.Range{
        .start = ast.extra[expr.value + offset],
        .end = ast.extra[expr.value + offset + 1],
    };

    const defRange = defines.Range{
        .start = ast.extra[expr.value + 2],
        .end = ast.extra[expr.value + 3],
    };

    var tags = allocator.alloc([]const u8, fieldRange.len()) catch return error.AllocatorFailure;
    var fields = allocator.alloc(Types.FieldInfo, fieldRange.len() + 1) catch return error.AllocatorFailure;
    var defs = allocator.alloc(Types.FieldInfo, defRange.len()) catch return error.AllocatorFailure;
    _ = &defs;

    for (0..fieldRange.len()) |index| {
        const symbol = ast.signatures.get(ast.extra[fieldRange.at(@intCast(index))]);

        const symbolToken = tokens.get(symbol.name);
        const symbolName = symbolToken.lexeme(self.typechecker.context, self.typechecker.currentFile);

        fields[index] = Types.FieldInfo{
            .public = symbol.public,
            .name = symbolName,
            .valueType = (try self.typechecker.expectType(symbol.type)).at(0),
        };

        tags[index] = symbolName;
    }

    const tagType = Types.TypeInfo{
        .Enum = .{
            .mutable = false,
            .name = try self.generateRandomName(.Enum),
            .definitions = &.{},
            .fields = tags,
        },
    };

    const tag =
        if (tagged) 0
        else (try self.typechecker.registerType(tagType)).at(0);

    for (0..defRange.len()) |index| {
        const declPtr = self.typechecker.symbols.findDecl(.{
            .file = self.typechecker.currentFile,
            .expr = ast.extra[defRange.at(@intCast(index))],
        });
        const decl = self.typechecker.symbols.getDecl(declPtr);

        // TODO: Should I typecheck decls here?
        const declToken = tokens.get(decl.token);
        const declName = declToken.lexeme(self.typechecker.context, self.typechecker.currentFile);

        defs[index] = Types.FieldInfo{
            .public = decl.public,
            .name = declName,
            // TODO: mark incomplete for now
            .valueType = comptime Builtin.Type("incomplete").at(0),
        };
    }

    const newType: Types.TypeInfo =
        if (tagged) .{
            .Union = .{
                .Tagged = .{
                    .tag = tag,
                    .mutable = false,
                    .name = try self.generateRandomName(.Union),
                    .fields = fields,
                    .definitions = defs,
                },
            },
        }
        else .{
            .Union = .{
                .Plain = .{
                    .mutable = false,
                    .name = try self.generateRandomName(.Union),
                    .fields = fields,
                    .definitions = defs,
                },
            },
        };

    const typeID = try self.typechecker.registerType(newType);
    return .{ .Type = typeID.at(0) };
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

pub fn constructUndefined(self: *Comptime, valueType: Types.TypeID) Error!Value {
    return switch (self.typechecker.typeTable.get(valueType)) {
        .Pointer, .Function, .Type, .Any, .Noreturn, .EnumLiteral => {
            self.report("Given type '{s}' can't be undefined.", .{
                self.typechecker.typeName(self.arena.allocator(), valueType)
            });
            return error.IllegalSyntax;
        },
        else => .{ .Undefined = valueType },
    };
}

fn generateRandomName(self: *Comptime, comptime mode: enum {
    Function,
    Enum,
    Struct,
    Union,
}) Error![]const u8 {
    const randint = 0; // self.rng.next();

    return std.fmt.allocPrint(self.arena.allocator(), "anon_"++@tagName(mode)++"_{d}", .{
        randint
    }) catch error.AllocatorFailure;
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
    .{ .name = "string", .info = .{ .Pointer = .{ .mutable = false, .child = 2, .size = .Slice, }, } },
    // mut any
    .{ .name = "mut any", .info = .{ .Any = true } },
    // entry point
    .{ .name = "entry_point", .info = .{ .Function = .{.mutable = false, .argTypes = &.{ 6 }, .returnTypes = &.{ 1 } } } },
    // incomplete
    .{ .name = "incomplete", .info = .{ .Struct = .{ .mutable = true, .name = "incomplete", .fields = &.{}, .definitions = &.{} } } },
};
