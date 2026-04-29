const std = @import("std");
const common = @import("../core/common.zig");
const defines = @import("../core/defines.zig");
const collections = @import("../util/collections.zig");
const Types = @import("type.zig");

const assert = std.debug.assert;

const Lexer = @import("../lexer/lexer.zig");
const Parser = @import("../parser/parser.zig");
const Typechecker = @import("typechecker.zig");
const Resolver = @import("resolver.zig");
const Allocator = std.mem.Allocator;
const Arena = std.heap.ArenaAllocator;
const Error = common.CompilerError;

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
    Multi: struct {
        Size: u32,
        Values: ValuePtr,
    },
    Slice: struct {
        const Self = @This();

        Type: Types.TypeID, 
        Size: u32,
        To: ValuePtr,

        pub fn at(self: *const Self, index: u32) ValuePtr {
            assert(index < self.Size);
            return self.To + index;
        }
    },
    Function: Types.TypeID, // TODO: Function Ptrs, after typechecker ast of course.
    Void: void,
    Undefined: Types.TypeID,
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

pub fn attemptEval(self: *Comptime, exprPtr: defines.ExpressionPtr, maybeExpected: ?defines.Range) ?Value {
    const prev = self.setFlag(.Attempting, true);
    defer _ = self.setFlag(.Attempting, prev);
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
        .Literal => try self.evalLiteral(expr.value),
        .PointerType => try self.evalPtrType(.Single, expr.value),
        .MutableType => try self.evalMutType(expr.value),
        .ArrayType => try self.evalArrType(expr.value),
        .SliceType => try self.evalPtrType(.Slice, expr.value),
        .CPointerType => try self.evalPtrType(.C, expr.value),
        .FunctionType => try self.evalFuncType(expr.value),
        .EnumDefinition => try self.evalEnumType(expr.value),
        .StructDefinition => try self.evalStructType(expr.value),
        .UnionDefinition => try self.evalUnionType(expr.value),
        .Indexing => try self.evalIndexing(expr.value),
        .Call => try self.evalCall(expr.value, maybeExpected),
        .Lambda => try self.evalLambda(expr.value, maybeExpected),
        else => |t| {
            self.report("Unable to resolve comptime expression. ({s})", .{
                @tagName(t)
            });
            return error.ComptimeNotPossible;
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
        .Builtin => try self.evalBuiltin(&decl, maybeExpected),
        .Variable => try self.eval(decl.node, maybeExpected),
        else => |t| {
            self.report("{s} declaration is not implemented.", .{@tagName(t)});
            return error.NotImplemented;
        },
    };
}

fn evalBuiltinCall(self: *Comptime, extraPtr: defines.ExpressionPtr, declPtr: defines.DeclPtr, maybeExpected: ?defines.Range) Error!Value {
    const BI = Resolver.BuiltinIndex;

    const ast = self.typechecker.context.getAST(self.typechecker.currentFile);

    return switch (declPtr) {
        BI("cast") => self.evalCast(extraPtr, maybeExpected),
        BI("as") => self.evalTypeForwarding(extraPtr, maybeExpected),
        BI("typeOf") => .{
            .Type = (try self.typechecker.typecheckExpression(ast.extra[extraPtr + 1], null)).at(0),
        },
        else => {
            self.report("Builtin '{s}' is not suitable in this context.", .{Resolver.builtins[declPtr]});
            return error.ComptimeNotPossible;
        },
    };
}

fn evalBuiltin(self: *Comptime, decl: *const Resolver.Declaration, maybeExpected: ?defines.Range) Error!Value {
    const BI = Resolver.BuiltinIndex;

    return
        if (Builtin.isBuiltinType(decl.type)) .{
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
                self.report("Builtin '{s}' is not suitable in this context.", .{Resolver.builtins[decl.type]});
                return error.IllegalSyntax;
            },
        };
}

fn evalLiteral(self: *Comptime, tokenPtr: defines.TokenPtr) Error!Value {
    const token = self.typechecker.context.getTokens(self.typechecker.currentFile).get(tokenPtr);
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
        .String => .{
            .Slice = .{
                .Type = comptime Builtin.Type("string").at(0),
                .Size = @intCast(lexeme.len),
                .To = 0,
            },
        },
        else => unreachable,
    };
}

fn evalPtrType(
    self: *Comptime,
    comptime ptrType: @FieldType(Types.Pointer, "size"),
    innerType: defines.ExpressionPtr
) Error!Value {
    const prev = self.setFlag(.CanCycle, true);
    defer _ = self.setFlag(.CanCycle, prev);
    const inner = self.expectType(innerType) catch |err| switch (err) {
        error.DependencyCycle => Value{
            .Type = comptime Builtin.Type("incomplete").at(0),
        },
        else => return err,
    };

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

fn evalFuncType(self: *Comptime, extraPtr: defines.OpaquePtr) Error!Value {
    const allocator = self.arena.allocator();
    const ast = self.typechecker.context.getAST(self.typechecker.currentFile);

    const args = try self.eval(ast.extra[extraPtr], null);
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

    const returns = try self.eval(ast.extra[extraPtr + 1], null);
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

fn evalEnumType(self: *Comptime, extraPtr: defines.OpaquePtr) Error!Value {
    const allocator = self.arena.allocator();
    const ast = self.typechecker.context.getAST(self.typechecker.currentFile);
    const tokens = self.typechecker.context.getTokens(ast.tokens);

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
        const lexeme = token.lexeme(self.typechecker.context, self.typechecker.currentFile);
        fields[index] = lexeme;
    }

    const newType = Types.TypeInfo{
        .Enum = .{
            .mutable = false,
            .name = try self.generateRandomName(.Enum),
            .fields = fields,
            .definitions = try self.handleScopeDecls(ast, tokens, defRange),
        },
    };

    const typeID = try self.typechecker.registerType(newType);
    return .{ .Type = typeID.at(0) };
}

fn evalStructType(self: *Comptime, extraPtr: defines.OpaquePtr) Error!Value {
    const allocator = self.arena.allocator();
    const ast = self.typechecker.context.getAST(self.typechecker.currentFile);
    const tokens = self.typechecker.context.getTokens(ast.tokens);

    const fieldRange = defines.Range{
        .start = ast.extra[extraPtr],
        .end = ast.extra[extraPtr + 1],
    };

    const defRange = defines.Range{
        .start = ast.extra[extraPtr + 2],
        .end = ast.extra[extraPtr + 3],
    };

    var fields = allocator.alloc(Types.FieldInfo, fieldRange.len()) catch return error.AllocatorFailure;

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

    const newType = Types.TypeInfo{
        .Struct = .{
            .mutable = false,
            .name = try self.generateRandomName(.Struct),
            .fields = fields,
            .definitions = try self.handleScopeDecls(ast, tokens, defRange),
        },
    };

    const typeID = try self.typechecker.registerType(newType);
    return .{ .Type = typeID.at(0) };
}

fn evalUnionType(self: *Comptime, extraPtr: defines.OpaquePtr) Error!Value {
    const allocator = self.arena.allocator();
    const ast = self.typechecker.context.getAST(self.typechecker.currentFile);
    const tokens = self.typechecker.context.getTokens(ast.tokens);

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
        const symbolName = symbolToken.lexeme(self.typechecker.context, self.typechecker.currentFile);

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

    const fields = try self.handleScopeFields(ast, tokens, fieldRange);
    const defs = try self.handleScopeDecls(ast, tokens, defRange);

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

fn evalCast(self: *Comptime, extraPtr: defines.OpaquePtr, maybeExpected: ?defines.Range) Error!Value {
    const targetTypeRange =
        if (maybeExpected) |target| target
        else {
            self.report("Casting requires a known target type.", .{});
            return error.InferenceError;
        };

    const ast = self.typechecker.context.getAST(self.typechecker.currentFile);

    const expressionList = ast.expressions.items(.value)[ast.extra[extraPtr + 1]];
    const thingToCastRange = defines.Range{
        .start = ast.extra[expressionList],
        .end = ast.extra[expressionList + 1],
    };

    if (thingToCastRange.len() != 1 or targetTypeRange.len() != 1) {
        self.report("Multi-value type casting is not supported (yet).", .{});
        return error.NotImplemented;
    }
    else if (thingToCastRange.len() != targetTypeRange.len()) {
        self.report("Type count mismatch, expected {d}, received {d} values.", .{
            targetTypeRange.len(),
            thingToCastRange.len(),
        });
        return error.SizeMismatch;
    }

    const thingToCast = try self.eval(ast.extra[thingToCastRange.at(0)], null);
    const thingToCastTypeRange = try self.typechecker.typecheckValue(thingToCast);

    const targetType = targetTypeRange.at(0);
    const thingToCastType = thingToCastTypeRange.at(0);

    self.typechecker.assertCastable(thingToCastType, targetType) catch |err| {
        const rargs = .{
            self.typechecker.typeName(self.arena.allocator(), thingToCastType),
            self.typechecker.typeName(self.arena.allocator(), targetType),
        };

        switch (err) {
            error.IncompatibleTypes => self.report("Given type '{s}' can't be cast to '{s}'.", rargs),
            error.SizeMismatch => self.report("Type '{s}' is too big for being cast to '{s}'.", rargs),
            error.MutabilityViolation => self.report("Cast from '{s}' to '{s}' ignores mutability specifiers.", rargs),
            error.PointerSizeMismatch => self.report("Illegal cast from unknown sized '{s}' to sized '{s}'.", rargs),
            error.StructuralMismatch => self.report("Illegal cast from structurally incompatible '{s}' to '{s}'", rargs),
            error.MismatchingSliceChildType => self.report("Cast from slice type '{s}' to '{s}' will alter the length of the slice.", rargs),
            error.InferenceError => self.report("Illegal cast from '{s}' to unknown type '{s}'.", rargs),
            error.RedundantCast => self.report("Unnecessary cast from type '{s}' to '{s}'.", rargs),
            else => return error.ShouldBeImpossible,
        }

        return err;
    };

    return self.castValue(thingToCast, targetType);
}

fn evalTypeForwarding(self: *Comptime, extraPtr: defines.OpaquePtr, maybeExpected: ?defines.Range) Error!Value {
    if (maybeExpected) |expected| {
        if (
            expected.len() > 1
            and !self.typechecker.castable(comptime Builtin.Type("any").at(0), expected.at(0))
        ) {
            self.report("Reduntant type forwarding in already inferable context.", .{ });
            return error.RedundantTypeForwarding;
        }
    }

    const ast = self.typechecker.context.getAST(self.typechecker.currentFile);

    const expressionList = ast.expressions.items(.value)[ast.extra[extraPtr + 1]];
    const args = defines.Range{
        .start = ast.extra[expressionList],
        .end = ast.extra[expressionList + 1],
    };

    if (args.len() != 2) {
        self.report("Expected 2 arguments, received {d}.", .{
            args.len(),
        });
        return error.ArgumentCountMismatch;
    }

    const typeToForward = (try self.expectType(ast.extra[args.at(0)])).Type;
    const res = try self.eval(ast.extra[args.at(1)], .{ .start = typeToForward, .end = typeToForward + 1 });

    if ((try self.typechecker.typecheckValue(res)).at(0) != typeToForward) {
        self.report("Expected en expression of type '{s}' here.", .{
            self.typechecker.typeName(self.arena.allocator(), typeToForward),
        });
        return error.TypeMismatch;
    }

    return res;
}

fn evalExpressionList(self: *Comptime, extraPtr: defines.OpaquePtr) Error!Value {
    const ast = self.typechecker.context.getAST(self.typechecker.currentFile);

    const exprs = defines.Range{
        .start = ast.extra[extraPtr],
        .end = ast.extra[extraPtr + 1],
    };
    
    const start = self.memory.items.len;
    for (0..exprs.len()) |index| {
        self.memory.append(self.arena.allocator(), try self.eval(ast.extra[exprs.at(@intCast(index))], null))
            catch return error.AllocatorFailure;
    }

    return .{
        .Multi = .{
            .Size = @intCast(self.memory.items.len - start),
            .Values = @intCast(start),
        },
    };
}

fn evalLambda(self: *Comptime, extraPtr: defines.OpaquePtr, maybeExpected: ?defines.Range) Error!Value {
    if (
        maybeExpected == null
        or
        maybeExpected.?.len() <= 0
        or
        switch (maybeExpected.?.at(0)) {
            Builtin.Type("any").at(0), Builtin.Type("mut any").at(0) => true,
            else => false,
        }
    ) {
        self.report("Couldn't infer the type of lambda expression.", .{});
        return error.InferenceError;
    }

    _ = extraPtr;
    unreachable;
}

fn evalCall(self: *Comptime, extraPtr: defines.OpaquePtr, maybeExpected: ?defines.Range) Error!Value {
    const ast = self.typechecker.context.getAST(self.typechecker.currentFile);

    if (ast.expressions.items(.type)[ast.extra[extraPtr]] == .Identifier) {
        if (self.typechecker.symbols.resolutionMap.get(.{
            .file = self.typechecker.currentFile,
            .expr = ast.extra[extraPtr], 
        })) |builtinPtr| {
            return self.evalBuiltinCall(extraPtr, builtinPtr, maybeExpected);
        }
    }

    self.report("Comptime function calls are not (yet) supported.", .{});
    return error.NotImplemented;
}

fn evalIndexing(
    self: *Comptime,
    extraPtr: defines.OpaquePtr,
) Error!Value {
    const lValue = !self.getFlag(.RValue);

    const ast = self.typechecker.context.getAST(self.typechecker.currentFile);

    const slice = try self.eval(ast.extra[extraPtr], null);
    blk: switch (slice) {
        .Slice => { },
        .Undefined => {
            if (lValue) {
                break :blk;
            }

            self.report("Attempt to index an undefined value.", .{});
            return error.MemoryViolation;
        },
        else => |t| {
            self.report("Given type '{s}' is not indexable. ({s})", .{
                self.typechecker.typeNameMany(self.arena.allocator(), try self.typechecker.typecheckValue(slice)),
                @tagName(t),
            });
            return error.TypeMismatch;
        },
    }

    const index = try self.eval(ast.extra[extraPtr + 1], null);
    switch (index) {
        .Int => { },
        else => |t| {
            self.report("Given type '{s}' is not suitable to be an index. ({s})", .{
                self.typechecker.typeNameMany(self.arena.allocator(), try self.typechecker.typecheckValue(index)),
                @tagName(t),
            });
            return error.TypeMismatch;
        },
    }

    if (slice.Slice.Size <= index.Int) {
        self.report("Index out of bounds. Size: {d}, Index: {d}.", .{
            slice.Slice.Size,
            index.Int,
        });
        return error.IndexOutOfBounds;
    }

    return
        if (lValue) self.memory.items[slice.Slice.at(@intCast(index.Int))]
        else ret: {
            const ptrType = Types.TypeInfo{
                .Pointer = .{
                    .mutable = true,
                    .child = self.typechecker.typeTable.get(slice.Slice.Type).Pointer.child,
                    .size = .Single,
                },
            };
            const ptrTypeID = (try self.typechecker.registerType(ptrType)).at(0);

            break :ret .{
                .Pointer = .{
                    .Type = ptrTypeID,
                    .To = slice.Slice.at(@intCast(index.Int)),
                },
            };
        };
}

fn evalMutType(self: *Comptime, extraPtr: defines.OpaquePtr) Error!Value {
    const inner = try self.expectType(extraPtr);

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

fn evalArrType(self: *Comptime, extraPtr: defines.OpaquePtr) Error!Value {
    const ast = self.typechecker.context.getAST(self.typechecker.currentFile);

    const size = switch (try self.eval(ast.extra[extraPtr], null)) {
        .Int => |val|
            if (val <= std.math.maxInt(u32)) val
            else {
                self.report(
                    "Given value '{d}' exceeds the maximum supported array size of "
                    ++ "{d}.", .{
                        val,
                        std.math.maxInt(u32),
                    });
                return error.SizeViolation;
            },
        else => |tag| {
            self.report("Expected a 'comptime_int' value as size specifier. Got '{s}' instead.", .{@tagName(std.meta.activeTag(tag))});
            return error.TypeMismatch;
        },
    };

    const inner = try self.expectType(ast.extra[extraPtr + 1]);

    const newType = Types.TypeInfo{
        .Array = .{
            .len = @intCast(size),
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
        .Type = switch (try self.eval(exprPtr, comptime Builtin.Type("type"))) {
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
        .Function, .Type, .Any, .Noreturn, .EnumLiteral => {
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
    const randint = self.rng.next();

    return std.fmt.allocPrint(self.arena.allocator(), "anon_"++@tagName(mode)++"_{d}", .{
        randint
    }) catch error.AllocatorFailure;
}

fn handleScopeFields(
    self: *Comptime,
    ast: *const Parser.AST,
    tokens: *const Lexer.TokenList.Slice,
    fieldRange: defines.Range,
) Error![]Types.FieldInfo {
    const allocator = self.arena.allocator();

    var fields = allocator.alloc(Types.FieldInfo, fieldRange.len() + 1) catch return error.AllocatorFailure;

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

    return fields;
}

// @Note Beware, scope declarations must be comptime since they are technically
// top-level declarations.
fn handleScopeDecls(
    self: *Comptime,
    ast: *const Parser.AST,
    tokens: *const Lexer.TokenList.Slice,
    defRange: defines.Range,
) Error![]Types.FieldInfo {
    const allocator = self.arena.allocator();

    var defSize: u32 = 0;
    for (0..defRange.len()) |index| {
        const defPtr = ast.extra[defRange.at(@intCast(index))];
        const valPtr: defines.OpaquePtr = ast.statements.items(.value)[defPtr];

        const defCount = ast.extra[valPtr + 1] - ast.extra[valPtr];
        defSize += defCount;
    }

    const defsBuffer = allocator.alloc(Types.FieldInfo, defSize) catch return error.AllocatorFailure;
    var defs = std.ArrayList(Types.FieldInfo).initBuffer(defsBuffer);

    for (0..defRange.len()) |defIndex| {
        const defPtr = ast.extra[defRange.at(@intCast(defIndex))];
        const valPtr: defines.OpaquePtr = ast.statements.items(.value)[defPtr];

        const defSigRange = defines.Range{
            .start = ast.extra[valPtr],
            .end = ast.extra[valPtr + 1],
        };

        for (0..defSigRange.len()) |sigIndex| {
            const sig = ast.signatures.get(ast.extra[defSigRange.at(@intCast(sigIndex))]);

            const symbolToken = tokens.get(sig.name);
            const symbolName = symbolToken.lexeme(self.typechecker.context, self.typechecker.currentFile);

            defs.appendAssumeCapacity(Types.FieldInfo{
                .public = sig.public,
                .name = symbolName,
                .valueType = (try self.typechecker.expectType(sig.type)).at(0),
            });
        }
    }

    return defs.items;
}

fn castValue(self: *Comptime, value: Value, to: Types.TypeID) Error!Value {
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
        .Int => |fromInt| switch (self.typechecker.typeTable.get(to)) {
            .Integer => value,
            else => .{ .Float = @floatFromInt(fromInt) },
        },
        .Bool => |fromBool| .{
            .Int = @intFromBool(fromBool),
        },
        .Enum => |fromEnum| .{
            .Enum = .{
                .Type = .{
                    .Type = to,
                    .Value = fromEnum.Type.Value,
                },
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
        .Slice => |slice| switch (self.typechecker.typeTable.get(to).Pointer.size) {
            .Single, .C => |size| .{
                .Pointer = .{
                    .Type = self.typechecker.typeMap.get(Types.TypeInfo{
                        .Pointer = .{
                            .mutable = self.typechecker.mutable(slice.Type), 
                            .size = size,
                            .child = self.typechecker.typeTable.get(slice.Type).Pointer.child,
                        },
                    }).?.at(0),
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
        else => error.ShouldBeImpossible,
    };
}

fn report(self: *Comptime, comptime fmt: []const u8, args: anytype) void {
    return
        if (self.getFlag(.Attempting)) {}
        else self.typechecker.report("COMPTIME: " ++ fmt, args);
}

fn setFlag(self: *Comptime, comptime flag: Flags, bit: bool) bool {
    defer self.flags.setValue(Flags.flag(flag), bit);
    return self.flags.isSet(Flags.flag(flag));
}

fn getFlag(self: *Comptime, comptime flag: Flags) bool {
    return self.flags.isSet(Flags.flag(flag));
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
