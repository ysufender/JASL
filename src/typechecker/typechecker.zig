const std = @import("std");
const common = @import("../core/common.zig");
const defines = @import("../core/defines.zig");
const collections = @import("../util/collections.zig");
const functional = @import("../util/functional.zig");
const Types = @import("type.zig");

const Printer = @import("../debug/ast_printer.zig").PrintContext;
const Parser = @import("../parser/parser.zig");
const Comptime = @import("comptime.zig");
const Resolver = @import("resolver.zig");
const ModuleList = @import("../parser/prepass.zig").ModuleList;
const Lexer = @import("../lexer/lexer.zig");
const TypeInfo = Types.TypeInfo;
const TypeID = Types.TypeID;
const MultiArrayList = std.MultiArrayList;
const Error = common.CompilerError;
const Context = common.CompilerContext;
const Arena = std.heap.ArenaAllocator;
const Allocator = std.mem.Allocator;
const Callstack = collections.StaticRingStack(defines.DeclPtr, defines.stackLimit);
const AnonMap = std.DynamicBitSetUnmanaged;

const BuiltinIndex = Resolver.BuiltinIndex;
const deepCopy = collections.deepCopy;
const assert = std.debug.assert;
const eql = std.meta.eql;

pub const TypeTable = MultiArrayList(TypeInfo);
pub const TypeMap = collections.HashMap(TypeInfo, TypeID);
pub const ResolutionMap = collections.HashMap(defines.DeclPtr, TypeID);
pub const MetadataMap = collections.HashMap(Element, []const defines.ExpressionPtr);
const LookupMap = collections.HashMap(defines.DeclPtr, TypecheckStatus);

const TypecheckStatus = struct {
    status: enum {
        Checked,
        InProgress,
        NotChecked,
    },

    types: TypeID,
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

    pub fn slice(typechecker: *const Constants) Slice {
        return .{
            .all = typechecker.all.slice(),
            .ints = typechecker.ints.items,
            .floats = typechecker.floats.items,
            .strings = typechecker.strings.items,
            .bools = typechecker.bools.items,
            .aggs = typechecker.aggs.items,
        };
    }
};

pub const Resolution = struct {
    types: TypeTable.Slice,
    resolutionMap: ResolutionMap,
    constants: Constants.Slice,

    pub fn get(typechecker: *const Resolution, key: defines.DeclPtr) TypeID {
        return typechecker.resolutionMap.get(key).?;
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

anonymousMap: AnonMap,

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
        typeMap.putAssumeCapacityNoClobber(builtin.info, @intCast(id));
    }

    return .{
        .context = context,
        .modules = modules,
        .typeTable = typeTable,
        .reso = reso,
        .typeMap = typeMap,
        .metadata = metadata,
        .lookup = lookup,
        .anonymousMap = AnonMap.initEmpty(arena.allocator(), typeMap.capacity()) catch return error.AllocatorFailure,
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

pub fn typecheck(typechecker: *Typechecker, allocator: Allocator) Error!Resolution {
    typechecker.currentFile = typechecker.modules.getItem("root", .dataIndex);
    
    if (!typechecker.modules.getItem("root", .symbolPtrs).contains("main")) {
        typechecker.report("Couldn't find an entry point in the root module.", .{});
        return error.MissingDefinition;
    }

    defer typechecker.arena.deinit();
    typechecker.executer = try Comptime.init(typechecker, allocator);

    // TODO:                                             This part is not really nice, fix it.
    const mainPtr = typechecker.symbols.lookup.get(.{ .scope = typechecker.modules.modules.len - 1, .name = "main" }).?;
    const mainType = try typechecker.typecheckDecl(mainPtr, null);
    if (mainType != Comptime.Builtin.Type("entry_point")) {
        const main = typechecker.symbols.getDecl(mainPtr);
        typechecker.lastToken = main.token;
        typechecker.report("Unexpected type of entry point 'main'. Expected '*fn void -> i32', received '{s}'", .{
            typechecker.typeName(allocator, mainType),
        });
        return error.TypeMismatch;
    }

    return collections.deepCopy(Resolution{
        .types = typechecker.typeTable.slice(), 
        .resolutionMap = typechecker.reso,
        .constants = typechecker.constants.slice(),
    }, allocator);
}

pub fn typecheckVariable(typechecker: *Typechecker, decl: *const Resolver.Declaration) Error!TypeID {
    const expected = try typechecker.expectType(decl.type);

    const initializer =
        if (
            decl.topLevel
            or expected == Comptime.Builtin.Type("type")
        )
            try typechecker.typecheckValue(try typechecker.executer.eval(decl.node, expected), expected)
        else
            try typechecker.typecheckExpression(decl.node, expected);

    const res =
        if (typechecker.suitable(expected, initializer))
            try typechecker.infer(expected, initializer)
        else  {
            typechecker.report(
                "Mismatching initializer type in variable definition."
                ++ " Expected '{s}', received '{s}'.", .{
                typechecker.typeName(typechecker.arena.allocator(), expected),
                typechecker.typeName(typechecker.arena.allocator(), initializer),
            });
            return error.TypeMismatch;
        };

    blk: switch (typechecker.typeTable.get(initializer)) {
        .Type => {
            const newType = (try typechecker.executer.eval(decl.node, expected)).Type;
            switch (typechecker.typeTable.get(newType)) {
                .Union, .Enum, .Struct => { },
                else => break :blk,
            }

            if (typechecker.anonymousMap.isSet(newType)) {
                break :blk;
            }

            typechecker.anonymousMap.set(newType);

            const ast = typechecker.context.getAST(typechecker.currentFile);
            const tokens = typechecker.context.getTokens(ast.tokens);

            const symName = tokens.get(decl.token).lexeme(typechecker.context, typechecker.currentFile);
            const namespace = typechecker.modules.modules.get(typechecker.modules.modules.len - typechecker.currentFile - 1).name;
            const newName = std.fmt.allocPrint(typechecker.arena.allocator(), "{s}::{s}", .{
                namespace,
                symName,
            }) catch return error.AllocatorFailure;

            typechecker.typeTable.set(newType, switch (typechecker.typeTable.get(newType)) {
                .Struct => |str| .{
                    .Struct = .{
                        .mutable = str.mutable,
                        .name = newName,
                        .fields = str.fields,
                        .definitions = str.definitions,
                    },
                },

                .Enum => |enm| .{
                    .Enum = .{
                        .mutable = enm.mutable,
                        .name = newName,
                        .definitions = enm.definitions,
                        .fields = enm.fields,
                    },
                },

                .Union => |uni| switch (uni) {
                    .Tagged => |tagged| TypeInfo{
                        .Union = .{
                            .Tagged = .{
                                .mutable = tagged.mutable,
                                .name = newName,
                                .tag = tagged.tag,
                                .fields = tagged.fields,
                                .definitions = tagged.definitions,
                            },
                        },
                    },
                    .Plain => |plain| TypeInfo{
                        .Union = .{
                            .Plain = .{
                                .mutable = plain.mutable,
                                .name = newName,
                                .fields = plain.fields,
                                .definitions = plain.definitions,
                            },
                        },
                    },
                },

                else => unreachable,
            });
        },
        else => { },
    }

    return res;
}

pub fn typecheckExpression(typechecker: *Typechecker, expressionPtr: defines.ExpressionPtr, maybeExpected: ?TypeID) Error!TypeID {
    const ast = typechecker.context.getAST(typechecker.currentFile);

    if (typechecker.executer.attemptEval(expressionPtr, maybeExpected)) |result| {
        return typechecker.typecheckValue(result, maybeExpected);
    }

    const expr = ast.expressions.get(expressionPtr);
    return switch (expr.type) {
        .Identifier => {
            typechecker.lastToken = expr.value;
            const decl = typechecker.symbols.findDecl(.{ .file = typechecker.currentFile, .expr = expressionPtr });
            return typechecker.typecheckDecl(decl, maybeExpected);
        },
        .Indexing => typechecker.typecheckIndexing(expr.value),
        .Call => typechecker.typecheckCall(expr.value, maybeExpected),
        .Scoping => typechecker.typecheckScoping(expressionPtr),
        else => |t| {
            typechecker.report("Unable to typecheck expression '{s}'.", .{@tagName(t)});
            return error.TypecheckingFailure;
        }
    };
}

pub fn typecheckValue(typechecker: *Typechecker, val: Comptime.Value, maybeExpected: ?TypeID) Error!TypeID {
    const expected =
        if (maybeExpected) |expected| expected
        else Comptime.Builtin.Type("any");

    return switch (val) {
        .Int => typechecker.infer(expected, Comptime.Builtin.Type("comptime_int"))
            catch Comptime.Builtin.Type("comptime_int"),
        .Float => typechecker.infer(expected, Comptime.Builtin.Type("comptime_float"))
            catch Comptime.Builtin.Type("comptime_float"),
        .Bool => Comptime.Builtin.Type("bool"),
        .Enum => |enumeration| enumeration.Type,
        .Union => |uni| uni.Type,
        .Struct => |str| str.Type,
        .Type => Comptime.Builtin.Type("type"),
        .Pointer => |ptr| ptr.Type,
        .Function => |func| func,
        .Void => Comptime.Builtin.Type("void"),
        .Undefined => |undef| undef,
        .Slice => |slice| slice.Type,
    };
}

pub fn typecheckScoping(typechecker: *Typechecker, expr: defines.ExpressionPtr) Error!TypeID {
    if (typechecker.symbols.resolutionMap.get(.{
        .file = typechecker.currentFile,
        .expr = expr,
    })) |decl| {
        return typechecker.typecheckDecl(decl, null);
    }

    const ast = typechecker.context.getAST(typechecker.currentFile);
    const tokens = typechecker.context.getTokens(ast.tokens);

    const extraPtr: defines.OpaquePtr = ast.expressions.items(.value)[expr];

    const lhsTypePtr =
        try typechecker.expectType(ast.extra[extraPtr]);
        //if (typechecker.executer.attemptEval(ast.extra[extraPtr], Comptime.Builtin.Type("type"))) |res| switch (res) {
        //    .Type => |t| t,
        //    else => |wrong| {
        //        typechecker.report("Attempt to scope a non-scoped expression of type '{s}'.", .{
        //            typechecker.typeName(typechecker.arena.allocator(), try typechecker.typecheckValue(wrong, null)),
        //        });
        //        return error.UnexpectedNonTypeExpression;
        //    },
        //}
        //else {
        //    typechecker.report("Expected a comptime-known expression on the left hand side of scoping.", .{});
        //    return error.ComptimeNotPossible;
        //};
    const lhsType = typechecker.typeTable.get(lhsTypePtr);

    const member = tokens.get(ast.extra[extraPtr + 1]).lexeme(typechecker.context, typechecker.currentFile);

    return ret: switch (lhsType) {
        .Enum => |enm| {
            for (enm.fields) |field| {
                if (std.mem.eql(u8, field, member)) {
                    break :ret lhsTypePtr;
                }
            }

            typechecker.report("Couldn't find definition '{s}' in type '{s}'.", .{
                member,
                enm.name,
            });
            break :ret error.MissingDefinition;
        },
        else => common.debug.NotImplemented(@src()),
    };
}

pub fn typecheckCall(typechecker: *Typechecker, extraPtr: defines.OpaquePtr, maybeExpected: ?TypeID) Error!TypeID {
    const ast = typechecker.context.getAST(typechecker.currentFile);

    if (ast.expressions.items(.type)[ast.extra[extraPtr]] == .Identifier) {
        if (typechecker.symbols.resolutionMap.get(.{
            .file = typechecker.currentFile,
            .expr = ast.extra[extraPtr], 
        })) |builtinPtr| {
            return typechecker.typecheckBuiltinCall(extraPtr, builtinPtr, maybeExpected);
        }
    }

    const func = switch (typechecker.typeTable.get(try typechecker.typecheckExpression(ast.extra[extraPtr], null))) {
        .Function => |func| func,
        else => {
            typechecker.report("Attemp to call non-function type '{s}'.", .{
                typechecker.typeName(typechecker.arena.allocator(), try typechecker.typecheckExpression(ast.extra[extraPtr], null)),
            });
            return error.IllegalSyntax;
        },
    };

    const exprList = ast.expressions.items(.value)[ast.extra[extraPtr + 1]];
    const args = ast.extra[
        ast.extra[exprList]
        ..
        ast.extra[exprList + 1]
    ];

    if (args.len != func.argTypes.len) {
        typechecker.report("Mismatching argument counts in function call. Expected {d}, received {d}.", .{
            func.argTypes.len,
            args.len,
        });
        return error.ArgumentCountMismatch;
    }

    for (func.argTypes, args, 0..) |arg, expr, index| {
        const exprType = try typechecker.typecheckExpression(expr, arg);

        if (exprType != arg) {
            typechecker.report(
                "Argument type mismatch in function call."
                ++ " In argument {d}: expected {s}, received {s}", .{
                index,
                typechecker.typeName(typechecker.arena.allocator(), arg),
                typechecker.typeName(typechecker.arena.allocator(), exprType),
            });
            return error.TypeMismatch;
        }
    }

    return func.returnType;
}

pub fn typecheckBuiltinCall(typechecker: *Typechecker, extraPtr: defines.ExpressionPtr, declPtr: defines.DeclPtr, maybeExpected: ?TypeID) Error!TypeID {
    const BI = Resolver.BuiltinIndex;

    return switch (declPtr) {
        BI("cast") => typechecker.typecheckCast(extraPtr, maybeExpected),
        BI("as") => typechecker.typecheckTypeForwarding(extraPtr, maybeExpected),
        BI("typeOf") => (try typechecker.executer.evalTypeOf(extraPtr)).Type,
        else => {
            typechecker.report("Builtin '{s}' is not suitable in this context.", .{Resolver.builtins[declPtr]});
            return error.ComptimeNotPossible;
        },
    };
}

pub fn typecheckCast(typechecker: *Typechecker, extraPtr: defines.OpaquePtr, maybeExpected: ?TypeID) Error!TypeID {
    const targetType =
        if (maybeExpected) |target| target
        else {
            typechecker.report("Casting requires a known target type.", .{});
            return error.InferenceError;
        };

    const ast = typechecker.context.getAST(typechecker.currentFile);

    const expressionList = ast.expressions.items(.value)[ast.extra[extraPtr + 1]];
    const thingToCastRange = defines.Range{
        .start = ast.extra[expressionList],
        .end = ast.extra[expressionList + 1],
    };

    if (thingToCastRange.len() != 1) {
        typechecker.report("Multi-value type casting is not supported.", .{});
        return error.NotImplemented;
    }

    const thingToCastType = try typechecker.typecheckExpression(ast.extra[thingToCastRange.at(0)], null);

    typechecker.assertCastable(thingToCastType, targetType) catch |err| {
        const rargs = .{
            typechecker.typeName(typechecker.arena.allocator(), thingToCastType),
            typechecker.typeName(typechecker.arena.allocator(), targetType),
        };

        switch (err) {
            error.IncompatibleTypes => typechecker.report("Given type '{s}' can't be cast to '{s}'.", rargs),
            error.SizeMismatch => typechecker.report("Type '{s}' is too big for being cast to '{s}'.", rargs),
            error.MutabilityViolation => typechecker.report("Cast from '{s}' to '{s}' ignores mutability specifiers.", rargs),
            error.PointerSizeMismatch => typechecker.report("Illegal cast from unknown sized '{s}' to sized '{s}'.", rargs),
            error.StructuralMismatch => typechecker.report("Illegal cast from structurally incompatible '{s}' to '{s}'", rargs),
            error.MismatchingSliceChildType => typechecker.report("Cast from slice type '{s}' to '{s}' will alter the length of the slice.", rargs),
            error.InferenceError => typechecker.report("Illegal cast from '{s}' to unknown type '{s}'.", rargs),
            error.RedundantCast => typechecker.report("Unnecessary cast from type '{s}' to '{s}'.", rargs),
            else => return common.debug.ShouldBeImpossible(@src()),
        }

        return err;
    };

    return targetType;
}

pub fn typecheckTypeForwarding(typechecker: *Typechecker, extraPtr: defines.OpaquePtr, maybeExpected: ?TypeID) Error!TypeID {
    const ast = typechecker.context.getAST(typechecker.currentFile);

    const expressionList = ast.expressions.items(.value)[ast.extra[extraPtr + 1]];
    const args = defines.Range{
        .start = ast.extra[expressionList],
        .end = ast.extra[expressionList + 1],
    };

    if (args.len() != 2) {
        typechecker.report("Expected 2 arguments, received {d}.", .{
            args.len(),
        });
        return error.ArgumentCountMismatch;
    }

    const typeToForward = try typechecker.expectType(ast.extra[args.at(0)]);

    if (maybeExpected) |expected| {
        switch (expected) {
            Comptime.Builtin.Type("any"),
            Comptime.Builtin.Type("mut any") => { },
            else => {
                if (typechecker.suitable(typeToForward, expected)) {
                    typechecker.report("Reduntant type forwarding in already inferable context.", .{ });
                    return error.RedundantTypeForwarding;
                }
            },
        }
    }

    const res = try typechecker.typecheckExpression(ast.extra[args.at(1)], typeToForward);
    if (res != typeToForward) {
        typechecker.report("Expected en expression of type '{s}' here.", .{
            typechecker.typeName(typechecker.arena.allocator(), typeToForward),
        });
        return error.TypeMismatch;
    }

    return res;
}

pub fn typecheckIndexing(typechecker: *Typechecker, extraPtr: defines.OpaquePtr) Error!TypeID {
    _ = typechecker;
    _ = extraPtr;
    return error.NotImplemented;
}

pub fn typecheckDecl(typechecker: *Typechecker, declPtr: defines.DeclPtr, maybeExpected: ?TypeID) Error!TypeID {
    const allocator = typechecker.arena.allocator();

    const decl = typechecker.symbols.declarations.get(declPtr);

    const prevToken = typechecker.lastToken;
    const prevFile = typechecker.currentFile;
    if (decl.kind != .Builtin) {
        typechecker.currentFile = typechecker.modules.modules.items(.dataIndex)[typechecker.symbols.scopes.items(.module)[decl.scope]];
        typechecker.lastToken = decl.token;
    }
    defer typechecker.lastToken = prevToken;
    defer typechecker.currentFile = prevFile;

    const isPresent = typechecker.lookup.getOrPut(allocator, declPtr) catch return error.AllocatorFailure;

    const ast = typechecker.context.getAST(typechecker.currentFile);
    const tokens = typechecker.context.getTokens(ast.tokens);

    if (isPresent.found_existing) {
        switch (isPresent.value_ptr.status) {
            .Checked => return isPresent.value_ptr.types,
            .InProgress => {
                if (!typechecker.executer.flags.isSet(Comptime.Flags.flag(.CanCycle))) {
                    typechecker.report("Dependency cycle detected. '{s}' depends on ittypechecker.", .{
                        tokens.get(decl.token).lexeme(typechecker.context, typechecker.currentFile),
                    });
                }
                return error.DependencyCycle;
            },
            else => unreachable,
        }
    }

    isPresent.value_ptr.* = .{
        .status = .InProgress,
        .types = 0,
    };

    typechecker.callstack.push(declPtr);

    const types = try switch (decl.kind) {
        .Builtin =>
            if (Comptime.Builtin.isBuiltinType(decl.type)) Comptime.Builtin.Type("type")
            else switch (decl.type) {
                BuiltinIndex("undefined") =>
                    if (maybeExpected) |expected| expected
                    else {
                        typechecker.report("Unable to resolve the type of undefined value.", .{});
                        return error.MissingTypeSpecifier;
                    },
                else => {
                    typechecker.report("Builtin '{s}' is not implemented.", .{Resolver.builtins[decl.type]});
                    return error.NotImplemented;
                },
            },
        .Variable => typechecker.typecheckVariable(&decl),
        .Namespace => {
            typechecker.report("Operations on namespaces are not allowed.", .{});
            return error.NamespaceAsValue;
        },
        else => {
            typechecker.report("{s} is not implemented.", .{@tagName(decl.kind)});
            return error.NotImplemented;
        },
    };

    isPresent.value_ptr.* = .{
        .status = .Checked,
        .types = types,
    };

    _ = typechecker.callstack.pop();
    return types;
}

pub fn registerType(typechecker: *Typechecker, newType: TypeInfo) Error!TypeID {
    const isPresent = typechecker.typeMap.getOrPut(typechecker.arena.allocator(), newType)
        catch return error.AllocatorFailure;

    if (!isPresent.found_existing) {
        const typeID = try typechecker.typeTable.addOne(typechecker.arena.allocator());
        isPresent.value_ptr.* = @intCast(typeID);

        typechecker.typeTable.set(typeID, newType);
    }

    return isPresent.value_ptr.*;
}

pub fn report(typechecker: *Typechecker, comptime fmt: []const u8, args: anytype) void {
    common.log.err(fmt, args);
    const token = typechecker.context.getTokens(typechecker.currentFile).get(typechecker.lastToken);
    const position = token.position(typechecker.context, typechecker.currentFile);

    common.log.err(("." ** 4) ++ " In {s} {d}:{d}", .{
        typechecker.context.getFileName(typechecker.currentFile),
        position.line,
        position.column,
    });
    token.printLocation(typechecker.arena.allocator(), typechecker.context, typechecker.currentFile, position, typechecker.callstack.size == 1);
    typechecker.dumpCallStack();
}

fn dumpCallStack(typechecker: *Typechecker) void {
    _ = typechecker.callstack.pop();
    while (typechecker.callstack.pop()) |declPtr| {
        const lastDecl = typechecker.symbols.getDecl(declPtr);
        const modulePtr = typechecker.symbols.scopes.get(lastDecl.scope).module;
        const module = typechecker.modules.modules.get(modulePtr);
        const token = typechecker.context.getTokens(module.dataIndex).get(lastDecl.token);
        const position = token.position(typechecker.context, module.dataIndex);
        common.log.err(("." ** 8) ++ " Required from '{s} {d}:{d}'", .{
            typechecker.context.getFileName(module.dataIndex),
            position.line,
            position.column,
        });
        token.printLocation(typechecker.arena.allocator(), typechecker.context, typechecker.currentFile, position, typechecker.callstack.empty());
    }
}

pub fn assertCastable(typechecker: *Typechecker, from: TypeID, to: TypeID) Error!void {
    const fmax = std.math.floatMax;
    const fmin = struct{fn fmin(comptime T: type) T { return -fmax(T); }}.fmin;

    const fromType = typechecker.typeTable.get(from);
    const toType = typechecker.typeTable.get(to);

    switch (to) {
        Comptime.Builtin.Type("any"),
        Comptime.Builtin.Type("mut any") => return error.InferenceError,
        else => { },
    }

    if (from == to) {
        return error.RedundantCast;
    }

    if (!typechecker.mutable(from) and typechecker.mutable(to)) {
        return error.MutabilityViolation;
    }

    switch (fromType) {
        .Enum, .Union, .Struct => try typechecker.assertStructurallyIdentical(from, to),
        .Bool => switch (toType) {
            .Integer => |int| try functional.throwIf(int.size <= 0, error.SizeMismatch),
            else => return error.IncompatibleTypes,
        },
        .ComptimeInt => try functional.throwIf(!typechecker.isInt(to), error.IncompatibleTypes),
        .ComptimeFloat => try functional.throwIf(!typechecker.isFloat(to), error.IncompatibleTypes),
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
            .Pointer => |toPtr| try typechecker.assertCastablePtr(fromPtr, toPtr),
            else => return error.IncompatibleTypes,
        },
        .Function => switch (toType) {
            .Function => { },
            else => return error.IncompatibleTypes,
        },
        .EnumLiteral => return common.debug.ShouldBeImpossible(@src()),
        .Any, .Type,
        .Noreturn, .Array,
        .Void => return error.IncompatibleTypes,
    }
}

pub fn castable(typechecker: *Typechecker, from: TypeID, to: TypeID) bool {
    typechecker.assertCastable(from, to) catch return false;
    return true;
}

pub fn assertCastablePtr(typechecker: *const Typechecker, this: Types.Pointer, that: Types.Pointer) Error!void {
    switch (this.size) {
        .Slice => try functional.throwIf(that.size == .Slice and typechecker.sizeOf(this.child) != typechecker.sizeOf(that.child), error.MismatchingSliceChildType),
        .Single => try functional.throwIf(that.size == .Slice, error.PointerSizeMismatch),
        .C => try functional.throwIf(that.size == .Slice, error.PointerSizeMismatch),
    }

    try functional.throwIf(!typechecker.mutable(this.child) and typechecker.mutable(that.child), error.MutabilityViolation);
}

/// Does no mutability check
pub fn assertStructurallyIdentical(typechecker: *const Typechecker, this: TypeID, that: TypeID) Error!void {
    const fromType = typechecker.typeTable.get(this);
    const toType = typechecker.typeTable.get(that);

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
        else => return common.debug.ShouldBeImpossible(@src()),
    }
}

pub fn structurallyIdentical(typechecker: *const Typechecker, this: TypeID, that: TypeID) bool {
    typechecker.assertStructurallyIdentical(this, that) catch return false;
    return true;
}

pub fn suitable(typechecker: *const Typechecker, expected: TypeID, got: TypeID) bool {
    typechecker.assertSuitable(expected, got) catch return false;
    return true;
}

pub fn assertSuitable(typechecker: *const Typechecker, this: TypeID, that: TypeID) Error!void {
    const thisType = typechecker.typeTable.get(this);
    const thatType = typechecker.typeTable.get(that);

    return switch (thatType) {
        .Noreturn => { },
        .Any => functional.throwIf(std.meta.activeTag(thatType) == .Any, error.TypeMismatch),
        else => switch (thisType) {
            .Any => { },
            .ComptimeInt, .Integer => functional.throwIf(!typechecker.isInt(that), error.TypeMismatch),
            .ComptimeFloat, .Float => functional.throwIf(!typechecker.isFloat(that), error.TypeMismatch),
            .Struct, .Union, .Enum => typechecker.assertStructurallyIdentical(this, that),
            else => functional.throwIf(this != that, error.TypeMismatch),
        },
    };
}

pub fn isInt(typechecker: *const Typechecker, maybeInt: TypeID) bool {
    return switch (typechecker.typeTable.get(maybeInt)) {
        .ComptimeInt, .Integer => true,
        else => false,
    };
}

pub fn isFloat(typechecker: *const Typechecker, maybeFloat: TypeID) bool {
    return switch (typechecker.typeTable.get(maybeFloat)) {
        .ComptimeFloat, .Float => true,
        else => false,
    };
}

pub fn assignable(typechecker: *const Typechecker, this: TypeID, that: TypeID) bool {
    return
        if (!typechecker.mutable(this)) false
        else typechecker.suitable(this, that);
}

pub fn infer(typechecker: *const Typechecker, this: TypeID, that: TypeID) Error!TypeID {
    try typechecker.assertSuitable(this, that);

    const thisType = std.meta.activeTag(typechecker.typeTable.get(this));
    const thatType = std.meta.activeTag(typechecker.typeTable.get(that));

    const resType = switch (thatType) {
        .Noreturn => that,
        else => switch (thisType) {
            .Any => that,
            .ComptimeInt, .ComptimeFloat => that,
            else => this,
        },
    };

    return resType;
}

pub fn expectType(typechecker: *Typechecker, exprPtr: defines.ExpressionPtr) Error!TypeID {
    return
        if (typechecker.executer.expectType(exprPtr)) |val| val.Type 
        else |err| err;
}

pub fn mutable(typechecker: *const Typechecker, typeID: TypeID) bool {
    return switch (typechecker.typeTable.get(typeID)) {
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

pub fn canBeMutable(typechecker: *const Typechecker, typeID: TypeID) bool {
    return switch (typechecker.typeTable.get(typeID)) {
        .Any, .Bool, .Float,
        .Struct, .Union, .Enum,
        .Integer, .Pointer, .Array,
        .Function => !typechecker.mutable(typeID),
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
                .returnType = func.returnType,
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
pub fn sizeOf(typechecker: *const Typechecker, of: TypeID) u32 {
    return ret: switch (typechecker.typeTable.get(of)) {
        .Pointer => @sizeOf(*void),
        .Function => @sizeOf(@TypeOf(&sizeOf)),
        .Enum => @sizeOf(u32),
        .Float, .ComptimeFloat => @sizeOf(f32),
        .Integer => |int| int.size,
        .Bool => @sizeOf(bool),
        .Void, .Noreturn, .EnumLiteral, .Type, .Any => 0,
        .Array => |arr| arr.len * typechecker.sizeOf(arr.child),
        .ComptimeInt => @sizeOf(i64),
        .Struct => |str| {
            var size: u32 = 0;
            for (str.fields) |field| {
                size += typechecker.sizeOf(field.valueType);
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
                size = @max(size, typechecker.sizeOf(field.valueType));
            }

            break :ret switch (uni) {
                .Tagged => size + @sizeOf(u32),
                .Plain => size,
            };
        },
    };
}

pub fn typeName(typechecker: *const Typechecker, allocator: Allocator, typeID: TypeID) []const u8 {
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
        else ret: switch (typechecker.typeTable.get(typeID)) {
            .Pointer => {
                const ptr: Types.Pointer = typechecker.typeTable.get(typeID).Pointer;
                const child = typechecker.typeName(allocator, ptr.child);

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
                const arr: Types.Array = typechecker.typeTable.get(typeID).Array;
                const child = typechecker.typeName(allocator, arr.child);

                const prefix = if (arr.mutable) "mut " else "";
                const size = std.fmt.allocPrint(allocator, "[{d}]", .{arr.len})
                    catch return "AllocatorFailure";

                const res = allocator.alloc(u8, child.len + prefix.len + size.len) catch break :ret "AllocatorFailure";
                break :ret std.fmt.bufPrint(res, "{s}{s}{s}", .{prefix, size, child}) catch unreachable;
            },
            .Struct, .Union, .Enum => typename(typechecker, allocator, typeID),
            .Function => |func| {
                var res: []const u8 = if (func.mutable) "mut *fn (" else "*fn (";

                for (0..func.argTypes.len) |index| {
                    res = std.fmt.allocPrint(allocator, "{s}{s}{s}", .{
                        res,
                        typechecker.typeName(allocator, func.argTypes[index]),
                        if (index == func.argTypes.len - 1) "" else ", ",
                    }) catch return "AllocatorFailure";
                }


                res = std.fmt.allocPrint(allocator, "{s}) -> {s}", .{
                    res,
                    typechecker.typeName(allocator, func.returnType),
                }) catch return "AllocatorFailure";

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

pub fn extendExtra(typechecker: *Typechecker, size: usize) common.CompilerError!TypeID {
    const start: defines.OpaquePtr = @intCast(typechecker.extra.items.len);
    _ = typechecker.extra.addManyAsSlice(typechecker.arena.allocator(), size) catch return error.AllocatorFailure;
    return .{
        .start = start,
        .end = @intCast(typechecker.extra.items.len),
    };
}
