const std = @import("std");
const common = @import("../core/common.zig");
const defines = @import("../core/defines.zig");
const collections = @import("../util/collections.zig");
const types = @import("type.zig");

const assert = std.debug.assert;

const Lexer = @import("../lexer/lexer.zig");
const Parser = @import("../parser/parser.zig");
const Typechecker = @import("typechecker.zig");
const Resolver = @import("resolver.zig");
const Allocator = std.mem.Allocator;
const Arena = std.heap.ArenaAllocator;
const Error = common.CompilerError;
const TypeID = types.TypeID;
const TypeInfo = types.TypeInfo;

const FlagMap = std.bit_set.IntegerBitSet(8);
const Cache = collections.HashMap(Resolver.ResolutionKey, ValuePtr);
const Memory = std.ArrayList(Value);

const ValuePtr = u32;

pub const Flags = enum(u3) {
    Attempting = 0,
    CanCycle = 1,
    RValue = 2,

    pub fn flag(flagToGet: Flags) u3 {
        return @intFromEnum(flagToGet);
    }
};

// TODO: Turn into a manually tagged union
// with possibly flattened fields for performance
// and memory usage
pub const Value = union(enum) {
    Int: i64,
    Float: f32,
    Bool: bool,
    Enum: struct {
        Type: TypeID,
        Value: u32,
    },
    Union: struct {
        Type: TypeID,
        Tag: u32,
        Value: ValuePtr,
    },
    Struct: struct {
        Type: TypeID,
        Fields: []const ValuePtr,
    },
    Type: TypeID,
    Pointer: struct {
        Type: TypeID,
        To: ValuePtr,
    },
    Slice: struct {
        const Self = @This();

        Type: TypeID, 
        Size: u32,
        To: ValuePtr,

        pub fn at(comptimer: *const Self, index: u32) ValuePtr {
            assert(index < comptimer.Size);
            return comptimer.To + index;
        }
    },
    Function: TypeID, // TODO: Function Ptrs, after typechecker ast of course.
    Void,
    Undefined: TypeID,
};

const Comptime = @This();

cache: Cache,
typechecker: *Typechecker,
arena: Arena,
gpa: Allocator,
flags: FlagMap,
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
        .flags = FlagMap.initEmpty(),
        .arena = arena,
        .rng = .init(5315),
    };
}

pub fn attemptEval(comptimer: *Comptime, exprPtr: defines.ExpressionPtr, maybeExpected: ?TypeID) ?Value {
    const prev = comptimer.setFlag(.Attempting, true);
    defer _ = comptimer.setFlag(.Attempting, prev);
    return comptimer.eval(exprPtr, maybeExpected) catch null;
}

pub fn eval(comptimer: *Comptime, exprPtr: defines.ExpressionPtr, maybeExpected: ?TypeID) Error!Value {
    const typechecker = comptimer.typechecker;
    const file = typechecker.currentFile;
    const ast = typechecker.context.getAST(comptimer.typechecker.currentFile);

    const key = Resolver.ResolutionKey{
        .file = file,
        .expr = exprPtr,
    };

    if (comptimer.cache.get(key)) |cached| {
        return comptimer.memory.items[cached];
    }

    const expr = ast.expressions.get(exprPtr);
    const value = switch (expr.type) {
        .Identifier =>
            if (expr.value == 0) Value{ .Type = comptime Builtin.Type("any") }
            else try comptimer.evalDecl(typechecker.symbols.findDecl(.{ .file = file, .expr = exprPtr }), maybeExpected),
        .Literal => try comptimer.evalLiteral(expr.value, maybeExpected),
        .PointerType => try comptimer.evalPtrType(.Single, expr.value),
        .SliceType => try comptimer.evalPtrType(.Slice, expr.value),
        .CPointerType => try comptimer.evalPtrType(.C, expr.value),
        .MutableType => try comptimer.evalMutType(expr.value),
        .ArrayType => try comptimer.evalArrType(expr.value),
        .FunctionType => try comptimer.evalFuncType(expr.value),
        .EnumDefinition => try comptimer.evalEnumType(expr.value),
        .StructDefinition => try comptimer.evalStructType(expr.value),
        .UnionDefinition => try comptimer.evalUnionType(expr.value),
        .Indexing => try comptimer.evalIndexing(expr.value),
        .Call => try comptimer.evalCall(expr.value, maybeExpected),
        .Lambda => try comptimer.evalLambda(expr.value, maybeExpected),
        .Scoping => try comptimer.evalScoping(exprPtr),
        else => |t| {
            comptimer.report("Unable to resolve comptime expression. ({s})", .{
                @tagName(t)
            });
            return error.ComptimeNotPossible;
        },
    };

    const ptr = try comptimer.memory.addOne(comptimer.arena.allocator());
    ptr.* = value;
    comptimer.cache.putNoClobber(comptimer.arena.allocator(), key, @intCast(comptimer.memory.items.len - 1))
        catch return error.AllocatorFailure;
    return value;
}

fn evalDecl(comptimer: *Comptime, declPtr: defines.DeclPtr, maybeExpected: ?TypeID) Error!Value {
    const decls = comptimer.typechecker.symbols.declarations;

    const decl  = decls.get(declPtr);

    const prevToken = comptimer.typechecker.lastToken;
    const prevFile = comptimer.typechecker.currentFile;
    if (decl.kind != .Builtin) {
        comptimer.typechecker.currentFile = comptimer.typechecker.modules.modules.items(.dataIndex)[comptimer.typechecker.symbols.scopes.items(.module)[decl.scope]];
        comptimer.typechecker.lastToken = decl.token;
    }
    defer comptimer.typechecker.lastToken = prevToken;
    defer comptimer.typechecker.currentFile = prevFile;

    _ = try comptimer.typechecker.typecheckDecl(declPtr, maybeExpected);

    return switch (decl.kind) {
        .Builtin => try comptimer.evalBuiltin(&decl, maybeExpected),
        .Variable => try comptimer.eval(decl.node, maybeExpected),
        else => |t| {
            comptimer.report("{s} declaration is not implemented.", .{@tagName(t)});
            return error.NotImplemented;
        },
    };
}

fn evalBuiltinCall(comptimer: *Comptime, extraPtr: defines.ExpressionPtr, declPtr: defines.DeclPtr, maybeExpected: ?TypeID) Error!Value {
    const BI = Resolver.BuiltinIndex;

    const ast = comptimer.typechecker.context.getAST(comptimer.typechecker.currentFile);

    return switch (declPtr) {
        BI("cast") => comptimer.evalCast(extraPtr, maybeExpected),
        BI("as") => comptimer.evalTypeForwarding(extraPtr, maybeExpected),
        BI("typeOf") => comptimer.evalTypeOf(ast.expressions.items(.value)[ast.extra[extraPtr + 1]]),
        else => {
            comptimer.report("Builtin '{s}' is not suitable in this context.", .{Resolver.builtins[declPtr]});
            return error.ComptimeNotPossible;
        },
    };
}

fn evalBuiltin(comptimer: *Comptime, decl: *const Resolver.Declaration, maybeExpected: ?TypeID) Error!Value {
    const BI = Resolver.BuiltinIndex;

    return
        if (Builtin.isBuiltinType(decl.type)) .{
            .Type = decl.type,
        }
        else switch (decl.type) {
            BI("undefined") =>
                if (maybeExpected) |expected|
                    if (comptimer.typechecker.suitable(expected, comptime Builtin.Type("any")))
                        comptimer.constructUndefined(expected)
                    else  {
                        comptimer.report("Given type '{s}' can't be undefined.", .{
                            comptimer.typechecker.typeName(comptimer.arena.allocator(), expected),
                        });
                        return error.MissingTypeSpecifier;
                    }
                else {
                    comptimer.report("Unable to infer the type of undefined value.", .{});
                    return error.MissingTypeSpecifier;
                },
            else => {
                comptimer.report("Builtin '{s}' is not suitable in this context.", .{Resolver.builtins[decl.type]});
                return error.IllegalSyntax;
            },
        };
}

fn evalLiteral(comptimer: *Comptime, tokenPtr: defines.TokenPtr, maybeExpected: ?TypeID) Error!Value {
    const token = comptimer.typechecker.context.getTokens(comptimer.typechecker.currentFile).get(tokenPtr);
    const lexeme = token.lexeme(comptimer.typechecker.context, comptimer.typechecker.currentFile);
    return switch (token.type) {
        .True, .False => .{ .Bool = token.type == .True },
        .Float => .{ .Float = std.fmt.parseFloat(f32, lexeme) catch unreachable },
        .Integer => .{ .Int = std.fmt.parseInt(u32, lexeme, 10) catch |err| switch (err) {
            error.Overflow => {
                comptimer.report("Given literal '{s}' is too big for comptime evaluation.", .{lexeme});
                return error.IntegerOverflow;
            },
            else => unreachable,
        }},
        .String => .{
            .Slice = .{
                .Type = comptime Builtin.Type("string"),
                .Size = @intCast(lexeme.len),
                .To = 0,
            },
        },
        .EnumLiteral =>
            if (maybeExpected) |expected| switch (comptimer.typechecker.typeTable.get(expected)) {
                .Enum => |enm| ret: for (enm.fields, 0..) |field, index| {
                    if (std.mem.eql(u8, field, lexeme[1..])) {
                        break :ret Value{
                            .Enum = .{
                                .Type = expected,
                                .Value = @intCast(index),
                            },
                        };
                    }
                } else {
                    comptimer.report("Couldn't find enumeration '{s}' in '{s}'.", .{
                        lexeme[1..],
                        comptimer.typechecker.typeName(comptimer.arena.allocator(), expected),
                    });
                    return error.FieldNotFound;
                },
                else => {
                    comptimer.report("Failed to resolve the type of enum literal '{s}'. Context requires type '{s}'.", .{
                        lexeme,
                        comptimer.typechecker.typeName(comptimer.arena.allocator(), expected),
                    });
                    return error.TypeMismatch;
                },
            }
            else {
                comptimer.report("Can't infer the type of enum literal '{s}'.", .{
                    lexeme,
                });
                return error.InferenceError;
            },
        else => unreachable,
    };
}

fn evalPtrType(
    comptimer: *Comptime,
    comptime ptrType: @FieldType(types.Pointer, "size"),
    innerType: defines.ExpressionPtr
) Error!Value {
    const prev = comptimer.setFlag(.CanCycle, true);
    defer _ = comptimer.setFlag(.CanCycle, prev);
    const inner = comptimer.expectType(innerType) catch |err| switch (err) {
        error.DependencyCycle => Value{
            .Type = comptime Builtin.Type("incomplete"),
        },
        else => return err,
    };

    const newType = TypeInfo{
        .Pointer = .{
            .size = ptrType,
            .mutable = false,
            .child = inner.Type,
        },
    };

    return .{
        .Type = (try comptimer.typechecker.registerType(newType)),
    };
}

fn evalFuncType(comptimer: *Comptime, extraPtr: defines.OpaquePtr) Error!Value {
    const ast = comptimer.typechecker.context.getAST(comptimer.typechecker.currentFile);

    const args = try comptimer.eval(ast.extra[extraPtr], null);
    const argSize: u32 = ret: switch (args) {
        .Slice => |slice| {
            var sub: u32 = 0;

            for (0..slice.Size) |index| {
                switch (comptimer.memory.items[slice.at(@intCast(index))]) {
                    .Type => |t| sub += if (t == Builtin.Type("void")) 1 else 0,
                    else => |t|{
                        comptimer.report("Expected a type expression, got '{s}' instead.", .{
                            @tagName(std.meta.activeTag(t)),
                        });
                    },
                }
            }

            break :ret slice.Size;
        },
        .Type => |t| if (t == Builtin.Type("void")) 0 else 1,
        else => |t| {
            comptimer.report(
                "Expected an argument type list in function type expression,"
                ++ " got '{s}' instead.", .{@tagName(std.meta.activeTag(t))});
            return error.TypeMismatch;
        },
    };

    const returnType = try comptimer.expectType(ast.extra[extraPtr + 1]);

    var argTypes = comptimer.arena.allocator().alloc(TypeID, argSize) catch return error.AllocatorFailure;

    switch (args) {
        .Type => |argType| if (argSize != 0) { argTypes[0] = argType; },
        .Slice => |slice| {
            var realIndex: u32 = 0;
            for (0..slice.Size) |index| {
                if (comptimer.memory.items[slice.at(@intCast(index))].Type != Builtin.Type("void")) {
                    argTypes[realIndex] = comptimer.memory.items[slice.at(@intCast(index))].Type;
                    realIndex += 1;
                }
            }
        },
        else => unreachable,
    }

    const typeID = try comptimer.typechecker.registerType(.{
        .Function = .{
            .mutable = false,
            .argTypes = argTypes,
            .returnType = returnType.Type,
        },
    });

    return .{
        .Type = typeID,
    };
}

fn evalEnumType(comptimer: *Comptime, extraPtr: defines.OpaquePtr) Error!Value {
    const allocator = comptimer.arena.allocator();
    const ast = comptimer.typechecker.context.getAST(comptimer.typechecker.currentFile);
    const tokens = comptimer.typechecker.context.getTokens(ast.tokens);

    const fieldRange = defines.Range{
        .start = ast.extra[extraPtr],
        .end = ast.extra[extraPtr + 1],
    };

    const defRange = defines.Range{
        .start = ast.extra[extraPtr + 2],
        .end = ast.extra[extraPtr + 3],
    };

    var fields = allocator.alloc([]const u8, fieldRange.len()) catch return error.AllocatorFailure;

    for (0..fieldRange.len()) |index| {
        const token = tokens.get(ast.extra[fieldRange.at(@intCast(index))]);
        const lexeme = token.lexeme(comptimer.typechecker.context, comptimer.typechecker.currentFile);
        fields[index] = lexeme;
    }

    const newType = TypeInfo{
        .Enum = .{
            .mutable = false,
            .name = try comptimer.generateRandomName(.Enum),
            .fields = fields,
            .definitions = try comptimer.handleScopeDecls(ast, tokens, defRange),
        },
    };

    const typeID = try comptimer.typechecker.registerType(newType);
    return .{ .Type = typeID };
}

fn evalStructType(comptimer: *Comptime, extraPtr: defines.OpaquePtr) Error!Value {
    const allocator = comptimer.arena.allocator();
    const ast = comptimer.typechecker.context.getAST(comptimer.typechecker.currentFile);
    const tokens = comptimer.typechecker.context.getTokens(ast.tokens);

    const fieldRange = defines.Range{
        .start = ast.extra[extraPtr],
        .end = ast.extra[extraPtr + 1],
    };

    const defRange = defines.Range{
        .start = ast.extra[extraPtr + 2],
        .end = ast.extra[extraPtr + 3],
    };

    var fields = allocator.alloc(types.FieldInfo, fieldRange.len()) catch return error.AllocatorFailure;

    for (0..fieldRange.len()) |index| {
        const symbol = ast.signatures.get(ast.extra[fieldRange.at(@intCast(index))]);

        const symbolToken = tokens.get(symbol.name);
        const symbolName = symbolToken.lexeme(comptimer.typechecker.context, comptimer.typechecker.currentFile);

        fields[index] = types.FieldInfo{
            .public = symbol.public,
            .name = symbolName,
            .valueType = (try comptimer.typechecker.expectType(symbol.type)),
        };
    }

    const newType = TypeInfo{
        .Struct = .{
            .mutable = false,
            .name = try comptimer.generateRandomName(.Struct),
            .fields = fields,
            .definitions = try comptimer.handleScopeDecls(ast, tokens, defRange),
        },
    };

    const typeID = try comptimer.typechecker.registerType(newType);
    return .{ .Type = typeID };
}

fn evalUnionType(comptimer: *Comptime, extraPtr: defines.OpaquePtr) Error!Value {
    const allocator = comptimer.arena.allocator();
    const ast = comptimer.typechecker.context.getAST(comptimer.typechecker.currentFile);
    const tokens = comptimer.typechecker.context.getTokens(ast.tokens);

    const tagged = ast.extra[extraPtr] == 1;
    const offset: u32 = if (tagged) 2 else 1;

    const fieldRange = defines.Range{
        .start = ast.extra[extraPtr + offset],
        .end = ast.extra[extraPtr + offset + 1],
    };

    const defRange = defines.Range{
        .start = ast.extra[extraPtr + offset + 2],
        .end = ast.extra[extraPtr + offset + 3],
    };

    var tags = allocator.alloc([]const u8, fieldRange.len()) catch return error.AllocatorFailure;

    for (0..fieldRange.len()) |index| {
        const symbolTokenPtr = ast.signatures.items(.name)[fieldRange.at(@intCast(index))];
        const symbolToken = tokens.get(symbolTokenPtr);
        const symbolName = symbolToken.lexeme(comptimer.typechecker.context, comptimer.typechecker.currentFile);

        tags[index] = symbolName;
    }

    const tagType = TypeInfo{
        .Enum = .{
            .mutable = false,
            .name = try comptimer.generateRandomName(.Enum),
            .definitions = &.{},
            .fields = tags,
        },
    };

    const tag =
        if (tagged) 0
        else (try comptimer.typechecker.registerType(tagType));

    const fields = try comptimer.handleScopeFields(ast, tokens, fieldRange);
    const defs = try comptimer.handleScopeDecls(ast, tokens, defRange);

    const newType: TypeInfo =
        if (tagged) .{
            .Union = .{
                .Tagged = .{
                    .tag = tag,
                    .mutable = false,
                    .name = try comptimer.generateRandomName(.Union),
                    .fields = fields,
                    .definitions = defs,
                },
            },
        }
        else .{
            .Union = .{
                .Plain = .{
                    .mutable = false,
                    .name = try comptimer.generateRandomName(.Union),
                    .fields = fields,
                    .definitions = defs,
                },
            },
        };

    const typeID = try comptimer.typechecker.registerType(newType);
    return .{ .Type = typeID };
}

fn evalCast(comptimer: *Comptime, extraPtr: defines.OpaquePtr, maybeExpected: ?TypeID) Error!Value {
    const targetType = try comptimer.typechecker.typecheckCast(extraPtr, maybeExpected);

    const ast = comptimer.typechecker.context.getAST(comptimer.typechecker.currentFile);

    const expressionList = ast.expressions.items(.value)[ast.extra[extraPtr + 1]];
    const thingToCastRange = defines.Range{
        .start = ast.extra[expressionList],
        .end = ast.extra[expressionList + 1],
    };

    if (thingToCastRange.len() != 1) {
        comptimer.report("Multi-value type casting is not supported.", .{});
        return error.NotImplemented;
    }

    const thingToCast = try comptimer.eval(ast.extra[thingToCastRange.at(0)], null);

    return comptimer.castValue(thingToCast, targetType);
}

pub fn evalTypeOf(comptimer: *Comptime, extraPtr: defines.OpaquePtr) Error!Value {
    const ast = comptimer.typechecker.context.getAST(comptimer.typechecker.currentFile);

    const args = defines.Range{
        .start = ast.extra[extraPtr],
        .end = ast.extra[extraPtr + 1],
    };

    if (args.len() != 1) {
        comptimer.report("'typeOf' expects a single expression argument, received {d}.", .{
            args.len(),
        });
        return error.ArgumentCountMismatch;
    }

    return .{
        .Type = try comptimer.typechecker.typecheckExpression(ast.extra[args.at(0)], Builtin.Type("type")),
    };
}

fn evalTypeForwarding(comptimer: *Comptime, extraPtr: defines.OpaquePtr, maybeExpected: ?TypeID) Error!Value {
    _ = try comptimer.typechecker.typecheckTypeForwarding(extraPtr, maybeExpected);

    const ast = comptimer.typechecker.context.getAST(comptimer.typechecker.currentFile);

    const expressionList = ast.expressions.items(.value)[ast.extra[extraPtr + 1]];
    const args = defines.Range{
        .start = ast.extra[expressionList],
        .end = ast.extra[expressionList + 1],
    };

    const typeToForward = (try comptimer.expectType(ast.extra[args.at(0)])).Type;
    return comptimer.eval(ast.extra[args.at(1)], typeToForward);
}

fn evalScoping(comptimer: *Comptime, expr: defines.ExpressionPtr) Error!Value {
    if (comptimer.typechecker.symbols.resolutionMap.get(.{
        .file = comptimer.typechecker.currentFile,
        .expr = expr,
    })) |decl| {
        return comptimer.evalDecl(decl, null);
    }

    const ast = comptimer.typechecker.context.getAST(comptimer.typechecker.currentFile);
    const tokens = comptimer.typechecker.context.getTokens(ast.tokens);

    const extraPtr = ast.expressions.items(.value)[expr];

    _ = try comptimer.typechecker.typecheckScoping(expr);
    const res = (try comptimer.expectType(ast.extra[extraPtr])).Type;

    const member = tokens
        .get(ast.extra[extraPtr + 1])
        .lexeme(comptimer.typechecker.context, ast.tokens);

    return switch (comptimer.typechecker.typeTable.get(res)) {
        .Enum => |enm| Value{
            .Enum = .{
                .Type = res,
                .Value = blk: for (enm.fields, 0..) |field, index| {
                    if (std.mem.eql(u8, field, member)) {
                        break :blk @intCast(index);
                    }
                } else unreachable
            },
        },
        else => |o| {
            std.debug.print("{s} is not implemented.\n", .{@tagName(std.meta.activeTag(o))});
            return common.debug.NotImplemented(@src());
        },
    };
}

fn evalLambda(comptimer: *Comptime, extraPtr: defines.OpaquePtr, maybeExpected: ?TypeID) Error!Value {
    const expected =
        if (maybeExpected) |expected| switch (expected) {
            Builtin.Type("any"), Builtin.Type("mut any") => {
                comptimer.report("Couldn't infer the type of lambda expression.", .{});
                return error.InferenceError;
            },
            else => switch (comptimer.typechecker.typeTable.get(expected)) {
                .Function => |func| func,
                else => {
                    comptimer.report("Expected '{s}', received lambda expression.", .{
                        comptimer.typechecker.typeName(comptimer.arena.allocator(), expected),
                    });
                    return error.TypeMismatch;
                },
            },
        }
        else {
            comptimer.report("Couldn't infer the type of lambda expression.", .{});
            return error.InferenceError;
        };

    const ast = comptimer.typechecker.context.getAST(comptimer.typechecker.currentFile);

    const paramsRange = defines.Range{
        .start = ast.extra[extraPtr],
        .end = ast.extra[extraPtr + 1],
    };

    if (paramsRange.len() != expected.argTypes.len) blk: {
        if (
            paramsRange.len() == 0
            and expected.argTypes.len == 1
            and expected.argTypes[0] == Builtin.Type("void")
        ) {
            break :blk;
        }

        comptimer.report(
            "Mismatching parameter counts in lambda expression. Expected {d}, received {d}", .{
                expected.argTypes.len,
                paramsRange.len(),
            }
        );
        return error.ArgumentCountMismatch;
    }

    const returnType = try comptimer.typechecker.typecheckExpression(
        ast.extra[extraPtr + 2],
        expected.returnType,
    );

    if (expected.returnType != returnType) {
        comptimer.report(
            "Mismatching return type in lambda expression. Expected '{s}', received '{s}'", .{
                comptimer.typechecker.typeName(comptimer.arena.allocator(), expected.returnType),
                comptimer.typechecker.typeName(comptimer.arena.allocator(), returnType),
            }
        );

        return error.TypeMismatch;
    }

    // @Unfinished
    return error.NotImplemented;
}

fn evalCall(comptimer: *Comptime, extraPtr: defines.OpaquePtr, maybeExpected: ?TypeID) Error!Value {
    const ast = comptimer.typechecker.context.getAST(comptimer.typechecker.currentFile);

    if (ast.expressions.items(.type)[ast.extra[extraPtr]] == .Identifier) {
        if (comptimer.typechecker.symbols.resolutionMap.get(.{
            .file = comptimer.typechecker.currentFile,
            .expr = ast.extra[extraPtr], 
        })) |builtinPtr| {
            return comptimer.evalBuiltinCall(extraPtr, builtinPtr, maybeExpected);
        }
    }

    comptimer.report("Comptime function calls are not (yet) supported.", .{});
    return error.NotImplemented;
}

fn evalIndexing(
    comptimer: *Comptime,
    extraPtr: defines.OpaquePtr,
) Error!Value {
    const lValue = !comptimer.getFlag(.RValue);

    const ast = comptimer.typechecker.context.getAST(comptimer.typechecker.currentFile);

    const slice = try comptimer.eval(ast.extra[extraPtr], null);
    blk: switch (slice) {
        .Slice => { },
        .Undefined => {
            if (lValue) {
                break :blk;
            }

            comptimer.report("Attempt to index an undefined value.", .{});
            return error.MemoryViolation;
        },
        else => |t| {
            comptimer.report("Given type '{s}' is not indexable. ({s})", .{
                comptimer.typechecker.typeName(comptimer.arena.allocator(), try comptimer.typechecker.typecheckValue(slice, null)),
                @tagName(t),
            });
            return error.TypeMismatch;
        },
    }

    const index = try comptimer.eval(ast.extra[extraPtr + 1], null);
    switch (index) {
        .Int => { },
        else => |t| {
            comptimer.report("Given type '{s}' is not suitable to be an index. ({s})", .{
                comptimer.typechecker.typeName(comptimer.arena.allocator(), try comptimer.typechecker.typecheckValue(index, null)),
                @tagName(t),
            });
            return error.TypeMismatch;
        },
    }

    if (slice.Slice.Size <= index.Int) {
        comptimer.report("Index out of bounds. Size: {d}, Index: {d}.", .{
            slice.Slice.Size,
            index.Int,
        });
        return error.IndexOutOfBounds;
    }

    return
        if (lValue) comptimer.memory.items[slice.Slice.at(@intCast(index.Int))]
        else ret: {
            const ptrType = TypeInfo{
                .Pointer = .{
                    .mutable = true,
                    .child = comptimer.typechecker.typeTable.get(slice.Slice.Type).Pointer.child,
                    .size = .Single,
                },
            };
            const ptrTypeID = (try comptimer.typechecker.registerType(ptrType));

            break :ret .{
                .Pointer = .{
                    .Type = ptrTypeID,
                    .To = slice.Slice.at(@intCast(index.Int)),
                },
            };
        };
}

fn evalMutType(comptimer: *Comptime, extraPtr: defines.OpaquePtr) Error!Value {
    const inner = try comptimer.expectType(extraPtr);

    if (comptimer.typechecker.canBeMutable(inner.Type)) {
        const typeInfo = comptimer.typechecker.typeTable.get(inner.Type);
        const typeID = try comptimer.typechecker.registerType(comptimer.typechecker.makeMutable(typeInfo));

        return .{
            .Type = typeID,
        };
    }
    else {
        comptimer.report("Redundant 'mut' specifier on already mutable type '{s}'.", .{
            comptimer.typechecker.typeName(comptimer.typechecker.arena.allocator(), inner.Type)
        });
        return error.InvalidSpecifier;
    }
}

fn evalArrType(comptimer: *Comptime, extraPtr: defines.OpaquePtr) Error!Value {
    const ast = comptimer.typechecker.context.getAST(comptimer.typechecker.currentFile);

    const size = switch (try comptimer.eval(ast.extra[extraPtr], null)) {
        .Int => |val|
            if (val <= std.math.maxInt(u32)) val
            else {
                comptimer.report(
                    "Given value '{d}' exceeds the maximum supported array size of "
                    ++ "{d}.", .{
                        val,
                        std.math.maxInt(u32),
                    });
                return error.SizeViolation;
            },
        else => |tag| {
            comptimer.report("Expected a 'comptime_int' value as size specifier. Got '{s}' instead.", .{@tagName(std.meta.activeTag(tag))});
            return error.TypeMismatch;
        },
    };

    const inner = try comptimer.expectType(ast.extra[extraPtr + 1]);

    const newType = TypeInfo{
        .Array = .{
            .len = @intCast(size),
            .mutable = false,
            .child = inner.Type,
        },
    };

    return .{
        .Type = (try comptimer.typechecker.registerType(newType)),
    };
}

pub fn expectType(comptimer: *Comptime, exprPtr: defines.ExpressionPtr) Error!Value {
    return .{
        .Type = switch (try comptimer.eval(exprPtr, comptime Builtin.Type("type"))) {
            .Type => |t| t,
            else => |otherwise| {
                comptimer.report("Expected a type expression, got '{s}' instead.", .{@tagName(otherwise)});
                return error.UnexpectedNonTypeExpression;
            },
        },
    };
}

pub fn constructUndefined(comptimer: *Comptime, valueType: TypeID) Error!Value {
    return switch (comptimer.typechecker.typeTable.get(valueType)) {
        .Function, .Type, .Any, .Noreturn, .EnumLiteral => {
            comptimer.report("Given type '{s}' can't be undefined.", .{
                comptimer.typechecker.typeName(comptimer.arena.allocator(), valueType)
            });
            return error.IllegalSyntax;
        },
        else => .{ .Undefined = valueType },
    };
}

fn generateRandomName(comptimer: *Comptime, comptime mode: @TypeOf(.EnumLiteral)) Error![]const u8 {
    const randint = comptimer.rng.next();

    return std.fmt.allocPrint(comptimer.arena.allocator(), "anon_"++@tagName(mode)++"_{d}", .{
        randint
    }) catch error.AllocatorFailure;
}

fn handleScopeFields(
    comptimer: *Comptime,
    ast: *const Parser.AST,
    tokens: *const Lexer.TokenList.Slice,
    fieldRange: defines.Range,
) Error![]types.FieldInfo {
    const allocator = comptimer.arena.allocator();

    var fields = allocator.alloc(types.FieldInfo, fieldRange.len() + 1) catch return error.AllocatorFailure;

    for (0..fieldRange.len()) |index| {
        const symbol = ast.signatures.get(ast.extra[fieldRange.at(@intCast(index))]);

        const symbolToken = tokens.get(symbol.name);
        const symbolName = symbolToken.lexeme(comptimer.typechecker.context, comptimer.typechecker.currentFile);

        fields[index] = types.FieldInfo{
            .public = symbol.public,
            .name = symbolName,
            .valueType = (try comptimer.typechecker.expectType(symbol.type)),
        };
    }

    return fields;
}

// @Note Beware, scope declarations must be comptime since they are technically
// top-level declarations.
fn handleScopeDecls(
    comptimer: *Comptime,
    ast: *const Parser.AST,
    tokens: *const Lexer.TokenList.Slice,
    defRange: defines.Range,
) Error![]types.FieldInfo {
    const allocator = comptimer.arena.allocator();

    const defsBuffer = allocator.alloc(types.FieldInfo, defRange.len()) catch return error.AllocatorFailure;
    var defs = std.ArrayList(types.FieldInfo).initBuffer(defsBuffer);

    for (0..defRange.len()) |defIndex| {
        const defPtr = ast.extra[defRange.at(@intCast(defIndex))];
        const valPtr: defines.OpaquePtr = ast.statements.items(.value)[defPtr];

        const signature = ast.extra[valPtr];

        const sig = ast.signatures.get(signature);
        const symbolToken = tokens.get(sig.name);
        const symbolName = symbolToken.lexeme(comptimer.typechecker.context, comptimer.typechecker.currentFile);

        defs.appendAssumeCapacity(types.FieldInfo{
            .public = sig.public,
            .name = symbolName,
            .valueType = Builtin.Type("incomplete"),
            // .valueType = (try comptimer.typechecker.expectType(sig.type)),
        });
    }

    return defs.items;
}

fn castValue(comptimer: *Comptime, value: Value, to: TypeID) Error!Value {
    return switch (value) {
        .Pointer => |ptr| .{
            .Pointer = .{
                .Type = to,
                .To = ptr.To,
            },
        },
        .Function => value, // TODO: Proper functions after typechecker AST
        .Float => |fromFloat| .{
            .Int = @intFromFloat(fromFloat),
        },
        .Int => |fromInt| switch (comptimer.typechecker.typeTable.get(to)) {
            .Integer => value,
            else => .{ .Float = @floatFromInt(fromInt) },
        },
        .Bool => |fromBool| .{
            .Int = @intFromBool(fromBool),
        },
        .Enum => |fromEnum| .{
            .Enum = .{
                .Type = to,
                .Value = fromEnum.Value,
            },
        },
        .Struct => |fromStruct| Value{
            .Struct = .{
                .Type = to,
                .Fields = fromStruct.Fields,
            },
        },
        .Union => |fromUni| Value{
            .Union = .{
                .Type = to,
                .Tag = fromUni.Tag,
                .Value = fromUni.Value,
            },
        },
        .Slice => |slice| switch (comptimer.typechecker.typeTable.get(to).Pointer.size) {
            .Single, .C => |size| .{
                .Pointer = .{
                    .Type = comptimer.typechecker.typeMap.get(TypeInfo{
                        .Pointer = .{
                            .mutable = comptimer.typechecker.mutable(slice.Type), 
                            .size = size,
                            .child = comptimer.typechecker.typeTable.get(slice.Type).Pointer.child,
                        },
                    }).?,
                    .To = slice.To,
                },
            },
            .Slice => .{
                .Slice = .{
                    .Size = slice.Size,
                    .To = slice.To,
                    .Type = to,
                },
            },
        },
        .Undefined => .{
            .Undefined = to, 
        },
        else => common.debug.ShouldBeImpossible(@src()),
    };
}

fn report(comptimer: *Comptime, comptime fmt: []const u8, args: anytype) void {
    return
        if (comptimer.getFlag(.Attempting)) {}
        else comptimer.typechecker.report("COMPTIME: " ++ fmt, args);
}

fn setFlag(comptimer: *Comptime, comptime flag: Flags, bit: bool) bool {
    defer comptimer.flags.setValue(Flags.flag(flag), bit);
    return comptimer.flags.isSet(Flags.flag(flag));
}

fn getFlag(comptimer: *Comptime, comptime flag: Flags) bool {
    return comptimer.flags.isSet(Flags.flag(flag));
}

pub fn deinit(comptimer: *Comptime) void {
    comptimer.arena.deinit();
}

pub const Builtin = struct {
    pub fn isBuiltinType(typeID: TypeID) bool {
        return typeID <= comptime Builtin.Type("any");
    }

    pub fn TypeName(btype: TypeID) []const u8 {
        assert(btype < builtins.len);
        return builtins[btype].name;
    }

    pub fn Type(btype: []const u8) TypeID {
        if (@typeInfo(@TypeOf(.{btype})).@"struct".fields[0].is_comptime) comptime {
            for (builtins, 0..) |item, index| {
                if (std.mem.eql(u8, item.name, btype)) {
                    return index;
                }
            }

            @compileError("Unknown type.");
        };

        for (builtins, 0..) |item, i| {
            if (std.mem.eql(u8, item.name, btype)) {
                return @intCast(i);
            }
        }

        unreachable;
    }
};

pub const builtins = [_]struct {
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
    // incomplete
    .{ .name = "incomplete", .info = .{ .Struct = .{ .mutable = true, .name = "incomplete", .fields = &.{}, .definitions = &.{} } } },
    // entry point
    .{ .name = "entry_point", .info = .{ .Function = .{.mutable = false, .argTypes = &.{6}, .returnType = 1 } } },
};
