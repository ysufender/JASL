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
    constants: Constants.Slice,

    pub fn get(self: *const Resolution, key: defines.DeclPtr) TypeID {
        return self.resolutionMap.get(key).?;
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
currentScope: defines.ScopePtr,
lastToken: defines.TokenPtr,
callstack: Callstack,

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
        .currentScope = 0,
        .lastToken = 0,
        .callstack = .{},
        .arena = arena,
    };
}

fn debugLog(self: *Typechecker) void {
    common.log.debug("Registered types:", .{});
    for (0..self.typeTable.len) |index| {
        common.log.debug("    {s}", .{
            self.typeName(self.arena.allocator(), @intCast(index)),
        });
    }
}

pub fn typecheck(self: *Typechecker, allocator: Allocator) Error!Resolution {
    // defer self.debugLog();

    if (!self.modules.getItem("root", .symbolPtrs).contains("main")) {
        self.report("Couldn't find an entry point in the root module.", .{});
        return error.MissingDefinition;
    }

    defer self.arena.deinit();
    self.executer = try Comptime.init(self, allocator);

    // TODO:                                             This part is not really nice, fix it.
    const mainPtr = self.symbols.lookup.get(.{ .scope = self.modules.modules.len - 1, .name = "main" }).?;
    const mainType = try self.typecheckDecl(mainPtr, null);
    if (mainType != Comptime.Builtin.Type("entry_point")) {
        const main = self.symbols.getDecl(mainPtr);
        self.lastToken = main.token;
        self.report("Unexpected type of entry point 'main'. Expected '*fn void -> i32', received '{s}'", .{
            self.typeName(allocator, mainType),
        });
        return error.TypeMismatch;
    }

    return collections.deepCopy(Resolution{
        .types = self.typeTable.slice(), 
        .resolutionMap = self.reso,
        .constants = self.constants.slice(),
    }, allocator);
}

pub fn typecheckVariable(self: *Typechecker, decl: *const Resolver.Declaration) Error!TypeID {
    const expected = try self.expectType(decl.type);

    const initializer =
        if (
            decl.topLevel
            or expected == Comptime.Builtin.Type("type")
        )
            try self.typecheckValue(try self.executer.eval(decl.node, expected), expected)
        else
            try self.typecheckExpression(decl.node, expected);

    const res =
        if (self.suitable(expected, initializer))
            try self.infer(expected, initializer)
        else  {
            self.report(
                "Mismatching initializer type in variable definition."
                ++ " Expected '{s}', received '{s}'.", .{
                self.typeName(self.arena.allocator(), expected),
                self.typeName(self.arena.allocator(), initializer),
            });
            return error.TypeMismatch;
        };

    blk: switch (self.typeTable.get(initializer)) {
        .Type => {
            const newType = (try self.executer.eval(decl.node, expected)).Type;
            const name = switch (self.typeTable.get(newType)) {
                .Union => |uni| uni.name,
                .Struct => |str| str.name,
                .Enum => |enm| enm.name,
                else => break :blk,
            };

            if (name[0] != '$') {
                break :blk;
            }

            const ast = self.context.getAST(self.currentFile);
            const tokens = self.context.getTokens(ast.tokens);

            const symName = tokens.get(decl.token).lexeme(self.context, self.currentFile);
            const namespace = self.modules.modules.get(self.modules.modules.len - self.currentFile - 1).name;
            const newName = std.fmt.allocPrint(self.arena.allocator(), "{s}::{s}", .{
                namespace,
                symName,
            }) catch return error.AllocatorFailure;

            self.typeTable.set(newType, switch (self.typeTable.get(newType)) {
                .Struct => |str| .{
                    .Struct = .{
                        .mutable = str.mutable,
                        .name = newName,
                        .fields = str.fields,
                        .definitions = str.definitions,
                        .scope = str.scope,
                    },
                },

                .Enum => |enm| .{
                    .Enum = .{
                        .mutable = enm.mutable,
                        .name = newName,
                        .definitions = enm.definitions,
                        .fields = enm.fields,
                        .scope = enm.scope,
                    },
                },

                .Union => |uni| TypeInfo{
                    .Union = .{
                        .name = newName,
                        .isTagged = uni.isTagged,
                        .tag = uni.tag,
                        .mutable = uni.mutable,
                        .definitions = uni.definitions,
                        .fields = uni.fields,
                        .scope = uni.scope,
                    },
                },

                else => unreachable,
            });
        },
        else => { },
    }

    return res;
}

pub fn typecheckExpression(self: *Typechecker, expressionPtr: defines.ExpressionPtr, maybeExpected: ?TypeID) Error!TypeID {
    const ast = self.context.getAST(self.currentFile);

    if (self.executer.attemptEval(expressionPtr, maybeExpected)) |result| {
        return self.typecheckValue(result, maybeExpected);
    }

    const expr = ast.expressions.get(expressionPtr);
    return switch (expr.type) {
        .Identifier => {
            self.lastToken = expr.value;
            const decl = self.symbols.findDecl(.{ .file = self.currentFile, .expr = expressionPtr });
            return self.typecheckDecl(decl, maybeExpected);
        },
        .Indexing => self.typecheckIndexing(expr.value),
        .Call => self.typecheckCall(expr.value, maybeExpected),
        .Scoping => self.typecheckScoping(expressionPtr),
        .ExpressionList => self.typecheckExpressionList(expr.value, maybeExpected),
        .Literal => self.typecheckValue(try self.executer.eval(expressionPtr, maybeExpected), maybeExpected),

        .EnumDefinition, .UnionDefinition, .StructDefinition,
        .ArrayType, .CPointerType, .FunctionType,
        .MutableType, .PointerType, .SliceType,
        .FunctionDefinition, .Lambda => self.typecheckValue(
            try self.executer.eval(
                expressionPtr,
                Comptime.Builtin.Type("type")
            ),
            Comptime.Builtin.Type("type"),
        ),

        else => |t| {
            self.report("Unable to typecheck expression '{s}'.", .{@tagName(t)});
            return error.TypecheckingFailure;
        }
    };
}

pub fn typecheckValue(self: *Typechecker, val: Comptime.Value, maybeExpected: ?TypeID) Error!TypeID {
    const expected =
        if (determineExpected(maybeExpected)) |expected| expected
        else Comptime.Builtin.Type("any");

    return switch (val) {
        .Int => self.infer(Comptime.Builtin.Type("comptime_int"), expected)
            catch Comptime.Builtin.Type("comptime_int"),
        .Float => self.infer(Comptime.Builtin.Type("comptime_float"), expected)
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

pub fn typecheckExpressionList(self: *Typechecker, extra: defines.OpaquePtr, _maybeExpected: ?TypeID) Error!TypeID {
    const maybeExpected = determineExpected(_maybeExpected);
    const ast = self.context.getAST(self.currentFile);

    const range = defines.Range{
        .start = ast.extra[extra],
        .end = ast.extra[extra + 1],
    };

    if (
        range.len() == 0
        and (
            maybeExpected == null
            or maybeExpected.? == Comptime.Builtin.Type("void")
        )
    ) {
        return Comptime.Builtin.Type("void");
    }

    const expected =
        if (maybeExpected) |expected| expected
        else if (range.len() == 1) {
            return self.typecheckExpression(ast.extra[range.at(0)], null);
        }
        else {
            self.report("Couldn't infer the type of expression list.", .{});
            return error.InferenceError;
        };

    return self.typecheckExpressionListRange(range, expected);
}

pub fn typecheckExpressionListRange(self: *Typechecker, range: defines.Range, expected: TypeID) Error!TypeID {
    const ast = self.context.getAST(self.currentFile);

    switch (self.typeTable.get(expected)) {
        .Enum => |enm| try self.typecheckEnumInitialization(ast, &enm, range, expected),
        .Struct => |str| try self.typecheckStructInitialization(ast, &str, range),
        .Union => |uni| try self.typecheckUnionInitialization(ast, &uni, range),
        .Array => |arr| try self.typecheckArrayInitialization(ast, &arr, range),
        .Pointer => |ptr| switch (ptr.size) {
            .Slice, .C => try self.typecheckGeneralInitialization(ast, ptr.child, range),
            .Single => {
                if (range.len() != 1) {
                    self.report("Can't initialize '{s}' with {d} values.", .{
                        self.typeName(self.arena.allocator(), expected),
                        range.len(),
                    });
                    return error.InitializerCountMismatch;
                }

                try self.typecheckGeneralInitialization(ast, expected, range);
            },
        },
        .Void, .Noreturn => try self.typecheckGeneralInitialization(ast, expected, range),
        .Type, .Function,
        .Bool, .Float, .Integer,
        .ComptimeInt, .ComptimeFloat => {
            if (range.len() != 1) {
                self.report("Can't initialize '{s}' with {d} values.", .{
                    self.typeName(self.arena.allocator(), expected),
                    range.len(),
                });
                return error.InitializerCountMismatch;
            }

            try self.typecheckGeneralInitialization(ast, expected, range);
        },
        else => return common.debug.NotImplemented(@src()),
    }

    return expected;
}

fn typecheckGeneralInitialization(self: *Typechecker, ast: *const Parser.AST, expected: TypeID, range: defines.Range) Error!void {
    for (range.start..range.end) |extraPtr| {
        const elem = try self.typecheckExpression(ast.extra[extraPtr], Comptime.Builtin.Type("void"));

        if (self.suitable(expected, elem)) {
            continue;
        }

        self.report("Mismatching types in initialization. Expected '{s}', received '{s}'.", .{
            self.typeName(self.arena.allocator(), expected),
            self.typeName(self.arena.allocator(), elem),
        });
        return error.TypeMismatch;
    }
}

fn typecheckEnumInitialization(self: *Typechecker, ast: *const Parser.AST, enm: *const Types.Enum, range: defines.Range, expected: TypeID) Error!void {
    if (range.len() != 1) {
        self.report("Expected an enum literal in enum initialization, received '{d}' expressions instead.", .{
            range.len(),
        });
        return error.ArgumentCountMismatch;
    }
    else {
        const rhs = try self.typecheckExpression(ast.extra[range.at(0)], expected);

        if (!self.suitable(expected, rhs)) {
            self.report("Expected an initializer of type '{s}', recieved '{s}' instead.", .{
                enm.name,
                self.typeName(self.arena.allocator(), rhs),
            });
            return error.TypeMismatch;
        }

        _ = try self.infer(expected, rhs);
    }
}

fn typecheckStructInitialization(self: *Typechecker, ast: *const Parser.AST, str: *const Types.Struct, range: defines.Range) Error!void {
    if (str.fields.len != range.len()) {
        self.report("Type '{s}' expects {d} initializer{s}, received {d}.", .{
            str.name,
            str.fields.len,
            if (str.fields.len > 1 or str.fields.len == 0) "s" else "",
            range.len(),
        });
        return error.InitializerCountMismatch;
    }

    for (str.fields, 0..) |field, index| {
        const initializerType = try self.typecheckExpression(
            ast.extra[range.at(@intCast(index))],
            field.valueType,
        );

        if (self.suitable(field.valueType, initializerType)) {
            continue;
        }

        self.report("'{s}::{s}' expected an initializer of type '{s}'. Received '{s}'.", .{
            str.name,
            field.name,
            self.typeName(self.arena.allocator(), field.valueType),
            self.typeName(self.arena.allocator(), initializerType),
        });
        return error.TypeMismatch;
    }
}

fn typecheckArrayInitialization(self: *Typechecker, ast: *const Parser.AST, arr: *const Types.Array, range: defines.Range) Error!void {
    if (arr.len != range.len()) {
        self.report("Mismatching elemen counts in array initialization. Expected {d}, received {d}.", .{
            arr.len,
            range.len(),
        });
        return error.InitializerCountMismatch;
    }

    for (0..arr.len) |index| {
        const item = try self.typecheckValue(
            try self.executer.eval(ast.extra[range.at(@intCast(index))], arr.child),
            arr.child,
        );

        if (self.suitable(arr.child, item)) {
            continue;
        }

        self.report(
            "Mismatching element types in array initialization."
            ++ " Expected '{s}', received '{s}' (at index {d})", .{
            self.typeName(self.arena.allocator(), arr.child),
            self.typeName(self.arena.allocator(), item),
            index,
        });
        return error.TypeMismatch;
    }
}

fn typecheckUnionInitialization(self: *Typechecker, ast: *const Parser.AST, uni: *const Types.Union, range: defines.Range) Error!void {
    if (range.len() < 1) {
        self.report("Expected a field enum in union initialization.", .{ });
        return error.InitializerCountMismatch;
    }

    const findex = switch (try self.executer.eval(ast.extra[range.at(0)], uni.tag)) {
        .Enum => |enm| blk: {
            if (enm.Type != uni.tag) {
                self.report("Expected field enum of type '{s}', received '{s}' instead.", .{
                    self.typeName(self.arena.allocator(), uni.tag),
                    self.typeName(self.arena.allocator(), enm.Type),
                });
                return error.TypeMismatch;
            }

            break :blk @as(u32, if (uni.isTagged) 1 else 0) + enm.Value;
        },
        else => |val| {
            self.report("Expected field enum of type '{s}', received '{s}' instead.", .{
                self.typeName(self.arena.allocator(), uni.tag),
                self.typeName(self.arena.allocator(),
                    try self.typecheckValue(val, null)
                ),
            });
            return error.TypeMismatch;
        }
    };

    const field = uni.fields[findex];
    _ = self.typecheckExpressionListRange(range.subRange(1), field.valueType) catch |err| {
        self.report("Error in union initialization '{s}::{s}' of type '{s}'.", .{
            uni.name,
            field.name,
            self.typeName(self.arena.allocator(), field.valueType),
        });
        return err;
    };
}

pub fn typecheckScoping(self: *Typechecker, expr: defines.ExpressionPtr) Error!TypeID {
    if (self.symbols.resolutionMap.get(.{
        .file = self.currentFile,
        .expr = expr,
    })) |decl| {
        return self.typecheckDecl(decl, null);
    }

    const ast = self.context.getAST(self.currentFile);
    const tokens = self.context.getTokens(ast.tokens);

    const extraPtr: defines.OpaquePtr = ast.expressions.items(.value)[expr];

    const lhsTypePtr = try self.expectType(ast.extra[extraPtr]);
    const lhsType = self.typeTable.get(lhsTypePtr);

    const member = tokens.get(ast.extra[extraPtr + 1]).lexeme(self.context, self.currentFile);

    var defs: []const Types.FieldInfo = undefined;
    var scope: defines.ScopePtr = undefined;
    switch (lhsType) {
        .Enum => |enm| {
            for (enm.fields) |field| {
                if (std.mem.eql(u8, field, member)) {
                    return lhsTypePtr;
                }
            }

            defs = enm.definitions;
            scope = enm.scope;
        },
        .Struct => |str| {
            defs = str.definitions;
            scope = str.scope;
        },
        .Union => |uni| {
            defs = uni.definitions;
            scope = uni.scope;
        },
        else => return common.debug.NotImplemented(@src()),
    }

    for (defs) |def| {
        if (std.mem.eql(u8, def.name, member)) {
            if (def.public or self.symbols.canAccess(self.currentScope, scope)) {
                return self.discoverScopeDef(lhsTypePtr, &def);
            }

            self.report("'{s}::{s}' is inaccessible due to its visibility level.", .{
                self.typeName(self.arena.allocator(), lhsTypePtr),
                member,
            });
            return error.AccessSpecifierMismatch;
        }
    }

    self.report("Couldn't find definition '{s}' in type '{s}'.", .{
        member,
        self.typeName(self.arena.allocator(), lhsTypePtr),
    });

    return error.MissingDefinition;
}

pub fn discoverScopeDef(self: *Typechecker, from: TypeID, member: *const Types.FieldInfo) Error!TypeID {
    if (member.valueType != Comptime.Builtin.Type("incomplete")) {
        return member.valueType;
    }

    const scope = switch (self.typeTable.get(from)) {
        .Enum => |enm| enm.scope,
        .Struct => |str| str.scope,
        .Union => |uni| uni.scope,
        else => return common.debug.ShouldBeImpossible(@src()),
    };

    const decl = self.symbols.lookup.get(.{
        .scope = scope,
        .name = member.name,
    }).?;

    const discoveredType = try self.typecheckDecl(decl, null);
    const memberIndex = try self.definitionIndex(from, member.name);

    switch (self.typeTable.get(from)) {
        .Enum => |enm| {
            var defs: []Types.FieldInfo = @constCast(enm.definitions);
            defs[memberIndex].valueType = discoveredType;

            self.typeTable.set(from, .{
                .Enum = .{
                    .name = enm.name,
                    .definitions = defs,
                    .scope = enm.scope,
                    .fields = enm.fields,
                    .mutable = enm.mutable,
                },
            });
        },
        .Struct => |str| {
            var defs: []Types.FieldInfo = @constCast(str.definitions);
            defs[memberIndex].valueType = discoveredType;

            self.typeTable.set(from, .{
                .Struct = .{
                    .name = str.name,
                    .definitions = defs,
                    .scope = str.scope,
                    .fields = str.fields,
                    .mutable = str.mutable,
                },
            });
        },
        .Union => |uni| {
            var defs: []Types.FieldInfo = @constCast(uni.definitions);
            defs[memberIndex].valueType = discoveredType;

            self.typeTable.set(from, .{
                .Union = .{
                    .isTagged = uni.isTagged,
                    .tag = uni.tag,
                    .name = uni.name,
                    .definitions = defs,
                    .scope = uni.scope,
                    .fields = uni.fields,
                    .mutable = uni.mutable,
                },
            });
        },
        else => return common.debug.ShouldBeImpossible(@src()),
    }

    return discoveredType;
}

pub fn typecheckCall(self: *Typechecker, extraPtr: defines.OpaquePtr, maybeExpected: ?TypeID) Error!TypeID {
    const ast = self.context.getAST(self.currentFile);

    if (ast.expressions.items(.type)[ast.extra[extraPtr]] == .Identifier) blk: {
        if (self.symbols.resolutionMap.get(.{
            .file = self.currentFile,
            .expr = ast.extra[extraPtr], 
        })) |builtinPtr| {
            const decl = self.symbols.declarations.get(builtinPtr);

            if (decl.kind != .Builtin) {
                break :blk;
            }

            if (Comptime.Builtin.isBuiltinType(decl.type)) {
                break :blk;
            }

            return self.typecheckBuiltinCall(extraPtr, decl.type, maybeExpected);
        }
    }

    const lhsType = try self.typecheckExpression(ast.extra[extraPtr], null);
    const maybeFunction = self.typeTable.get(lhsType);
    const func = switch (maybeFunction) {
        .Type => {
            const typeToInit = (try self.executer.eval(ast.extra[extraPtr], null)).Type;

            return self.typecheckExpressionList(
                ast.expressions.items(.value)[ast.extra[extraPtr + 1]],
                switch (self.typeTable.get(typeToInit)) {
                    .Type, .Noreturn, .Any,
                    .Function, .EnumLiteral => {
                        self.report("Given type '{s}' is not initializable.", .{
                            self.typeName(self.arena.allocator(), typeToInit),
                        });
                        return error.TypeIsNotConstructible;
                    },
                    .Pointer => |ptr| switch (ptr.size) {
                        .Single => {
                            self.report("Given type '{s}' is not initializable.", .{
                                self.typeName(self.arena.allocator(), typeToInit),
                            });
                            return error.TypeIsNotConstructible;
                        },
                        else => typeToInit,
                    },
                    else => typeToInit,
                },
            );
        },
        .Function => |func| func,
        else => {
            self.report("Attempt to call non-function type '{s}'.", .{
                self.typeName(self.arena.allocator(), lhsType),
            });
            return error.TypeIsNotCallable;
        },
    };

    const exprList = ast.expressions.items(.value)[ast.extra[extraPtr + 1]];
    const args = ast.extra[
        ast.extra[exprList]
        ..
        ast.extra[exprList + 1]
    ];

    if (args.len != func.argTypes.len) {
        self.report("Mismatching argument counts in function call. Expected {d}, received {d}.", .{
            func.argTypes.len,
            args.len,
        });
        return error.ArgumentCountMismatch;
    }

    for (func.argTypes, args, 0..) |arg, expr, index| {
        const exprType = try self.typecheckExpression(expr, arg);

        if (exprType != arg) {
            self.report(
                "Argument type mismatch in function call."
                ++ " In argument {d}: expected {s}, received {s}", .{
                index,
                self.typeName(self.arena.allocator(), arg),
                self.typeName(self.arena.allocator(), exprType),
            });
            return error.TypeMismatch;
        }
    }

    return func.returnType;
}

pub fn typecheckBuiltinCall(self: *Typechecker, extraPtr: defines.ExpressionPtr, declPtr: defines.DeclPtr, maybeExpected: ?TypeID) Error!TypeID {
    const BI = Resolver.BuiltinIndex;

    return switch (declPtr) {
        BI("cast") => self.typecheckCast(extraPtr, maybeExpected),
        BI("as") => self.typecheckTypeForwarding(extraPtr, maybeExpected),
        BI("typeOf") => (try self.executer.evalTypeOf(extraPtr)).Type,
        else => {
            self.report("Builtin '{s}' is not suitable in this context.", .{Resolver.builtins[declPtr]});
            return error.ComptimeNotPossible;
        },
    };
}

pub fn typecheckCast(self: *Typechecker, extraPtr: defines.OpaquePtr, maybeExpected: ?TypeID) Error!TypeID {
    const targetType =
        if (determineExpected(maybeExpected)) |target| target
        else {
            self.report("Casting requires a known target type.", .{});
            return error.InferenceError;
        };

    const ast = self.context.getAST(self.currentFile);

    const expressionList = ast.expressions.items(.value)[ast.extra[extraPtr + 1]];
    const thingToCastRange = defines.Range{
        .start = ast.extra[expressionList],
        .end = ast.extra[expressionList + 1],
    };

    if (thingToCastRange.len() != 1) {
        self.report("Multi-value type casting is not supported.", .{});
        return error.NotImplemented;
    }

    const thingToCastType = try self.typecheckExpression(ast.extra[thingToCastRange.at(0)], null);

    self.assertCastable(thingToCastType, targetType) catch |err| {
        const rargs = .{
            self.typeName(self.arena.allocator(), thingToCastType),
            self.typeName(self.arena.allocator(), targetType),
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
            else => return common.debug.ShouldBeImpossible(@src()),
        }

        return err;
    };

    return targetType;
}

pub fn typecheckTypeForwarding(self: *Typechecker, extraPtr: defines.OpaquePtr, maybeExpected: ?TypeID) Error!TypeID {
    const ast = self.context.getAST(self.currentFile);

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

    const typeToForward = try self.expectType(ast.extra[args.at(0)]);

    if (determineExpected(maybeExpected)) |expected| {
        if (self.suitable(typeToForward, expected)) {
            self.report("Reduntant type forwarding in already inferable context.", .{ });
            return error.RedundantTypeForwarding;
        }
    }

    const res = try self.typecheckExpression(ast.extra[args.at(1)], typeToForward);
    if (res != typeToForward) {
        self.report("Expected en expression of type '{s}' here.", .{
            self.typeName(self.arena.allocator(), typeToForward),
        });
        return error.TypeMismatch;
    }

    return res;
}

pub fn typecheckIndexing(self: *Typechecker, extraPtr: defines.OpaquePtr) Error!TypeID {
    // TODO: Finish this
    _ = self;
    _ = extraPtr;
    return error.NotImplemented;
}

pub fn typecheckDecl(self: *Typechecker, declPtr: defines.DeclPtr, maybeExpected: ?TypeID) Error!TypeID {
    const allocator = self.arena.allocator();

    const decl = self.symbols.declarations.get(declPtr);

    const prevToken = self.lastToken;
    const prevFile = self.currentFile;
    const prevScope = self.currentScope;
    if (decl.kind != .Builtin) {
        self.currentFile = self.modules.modules.items(.dataIndex)[self.symbols.scopes.items(.module)[decl.scope]];
        self.lastToken = decl.token;
        self.currentScope = decl.scope;
    }
    defer self.lastToken = prevToken;
    defer self.currentFile = prevFile;
    defer self.currentScope = prevScope;

    const isPresent = self.lookup.getOrPut(allocator, declPtr) catch return error.AllocatorFailure;

    const ast = self.context.getAST(self.currentFile);
    const tokens = self.context.getTokens(ast.tokens);

    if (isPresent.found_existing) {
        switch (isPresent.value_ptr.status) {
            .Checked =>
                if (isPresent.value_ptr.types != Comptime.Builtin.Type("incomplete"))
                    return isPresent.value_ptr.types
                else  { },
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
        .types = 0,
    };

    self.callstack.push(declPtr);

    const types = try switch (decl.kind) {
        .Builtin =>
            if (Comptime.Builtin.isBuiltinType(decl.type)) Comptime.Builtin.Type("type")
            else switch (decl.type) {
                BuiltinIndex("undefined") =>
                    if (determineExpected(maybeExpected)) |expected| expected
                    else {
                        self.report("Unable to resolve the type of undefined value.", .{});
                        return error.MissingTypeSpecifier;
                    },
                else => {
                    self.report("Builtin '{s}' is not implemented.", .{Resolver.builtins[decl.type]});
                    return error.NotImplemented;
                },
            },
        .Variable => self.typecheckVariable(&decl),
        .Namespace => {
            self.report("Operations on namespaces are not allowed.", .{});
            return error.NamespaceAsValue;
        },
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

pub fn registerType(self: *Typechecker, newType: TypeInfo) Error!TypeID {
    const isPresent = self.typeMap.getOrPut(self.arena.allocator(), newType)
        catch return error.AllocatorFailure;

    if (!isPresent.found_existing) {
        const typeID = try self.typeTable.addOne(self.arena.allocator());
        isPresent.value_ptr.* = @intCast(typeID);

        self.typeTable.set(typeID, newType);
    }

    return isPresent.value_ptr.*;
}

pub fn report(self: *Typechecker, comptime fmt: []const u8, args: anytype) void {
    common.log.err(fmt, args);
    const token = self.context.getTokens(self.currentFile).get(self.lastToken);
    const position = token.position(self.context, self.currentFile);

    common.log.err(("." ** 4) ++ " In {s} {d}:{d}", .{
        self.context.getFileName(self.currentFile),
        position.line,
        position.column,
    });
    token.printLocation(self.arena.allocator(), self.context, self.currentFile, position, self.callstack.size == 1);
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
        common.log.err(("." ** 8) ++ " Required from '{s} {d}:{d}'", .{
            self.context.getFileName(module.dataIndex),
            position.line,
            position.column,
        });
        token.printLocation(self.arena.allocator(), self.context, module.dataIndex, position, self.callstack.empty());
    }
}

pub fn assertCastable(self: *Typechecker, from: TypeID, to: TypeID) Error!void {
    const fmax = std.math.floatMax;
    const fmin = struct{fn fmin(comptime T: type) T { return -fmax(T); }}.fmin;

    const fromType = self.typeTable.get(from);
    const toType = self.typeTable.get(to);

    switch (to) {
        Comptime.Builtin.Type("any"),
        Comptime.Builtin.Type("mut any") => return error.InferenceError,
        else => { },
    }

    if (from == to) {
        return error.RedundantCast;
    }

    if (!self.mutable(from) and self.mutable(to)) {
        return error.MutabilityViolation;
    }

    switch (fromType) {
        .Enum => |enm| switch (toType) {
            .Enum => try self.assertStructurallyIdentical(from, to),
            .Integer => |int| {
                try functional.throwIf(int.range().max < enm.fields.len - 1, error.IncompatibleTypes);
            },
            .ComptimeInt => { },
            else => return error.IncompatibleTypes,
        },
        .Union, .Struct => try self.assertStructurallyIdentical(from, to),
        .Bool => switch (toType) {
            .Integer => |int| try functional.throwIf(int.size <= 0, error.SizeMismatch),
            else => return error.IncompatibleTypes,
        },
        .ComptimeInt => try functional.throwIf(!self.isInt(to), error.IncompatibleTypes),
        .ComptimeFloat => try functional.throwIf(!self.isFloat(to), error.IncompatibleTypes),
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
        .EnumLiteral => return common.debug.ShouldBeImpossible(@src()),
        .Any, .Type,
        .Noreturn, .Array,
        .Void => return error.IncompatibleTypes,
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
            if (fromUnion.isTagged != toUnion.isTagged) {
                return error.StructuralMismatch;
            }

            if (fromUnion.fields.len != toUnion.fields.len) {
                return error.StructuralMismatch;
            }

            for (fromUnion.fields, toUnion.fields) |fromField, toField| {
                if (!fromField.eql(toField)) {
                    return error.StructuralMismatch;
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

pub fn structurallyIdentical(self: *const Typechecker, this: TypeID, that: TypeID) bool {
    self.assertStructurallyIdentical(this, that) catch return false;
    return true;
}

pub fn suitable(self: *const Typechecker, expected: TypeID, got: TypeID) bool {
    self.assertSuitable(expected, got) catch return false;
    return true;
}

pub fn assertSuitable(self: *const Typechecker, this: TypeID, that: TypeID) Error!void {
    const thisType = self.typeTable.get(this);
    const thatType = self.typeTable.get(that);

    return switch (thatType) {
        .Noreturn => { },
        .Any => functional.throwIf(std.meta.activeTag(thatType) == .Any, error.TypeMismatch),
        else => switch (thisType) {
            .Any => { },
            .ComptimeInt, .Integer => functional.throwIf(!self.isInt(that), error.TypeMismatch),
            .ComptimeFloat, .Float => functional.throwIf(!self.isFloat(that), error.TypeMismatch),
            .Struct, .Union, .Enum => self.assertStructurallyIdentical(this, that),
            else => functional.throwIf(this != that, error.TypeMismatch),
        },
    };
}

pub fn isInt(self: *const Typechecker, maybeInt: TypeID) bool {
    return switch (self.typeTable.get(maybeInt)) {
        .ComptimeInt, .Integer => true,
        else => false,
    };
}

pub fn isFloat(self: *const Typechecker, maybeFloat: TypeID) bool {
    return switch (self.typeTable.get(maybeFloat)) {
        .ComptimeFloat, .Float => true,
        else => false,
    };
}

pub fn assignable(self: *const Typechecker, this: TypeID, that: TypeID) bool {
    return
        if (!self.mutable(this)) false
        else self.suitable(this, that);
}

pub fn infer(self: *const Typechecker, this: TypeID, that: TypeID) Error!TypeID {
    try self.assertSuitable(this, that);

    const thisType = std.meta.activeTag(self.typeTable.get(this));
    const thatType = std.meta.activeTag(self.typeTable.get(that));

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

pub fn expectType(self: *Typechecker, exprPtr: defines.ExpressionPtr) Error!TypeID {
    return
        if (self.executer.expectType(exprPtr)) |val| val.Type 
        else |err| err;
}

pub fn mutable(self: *const Typechecker, typeID: TypeID) bool {
    return switch (self.typeTable.get(typeID)) {
        .Any => |any| any,
        .Bool => |b| b,
        .Float => |fl| fl,
        .Struct => |str| str.mutable,
        .Union => |uni| uni.mutable,
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
                .scope = str.scope,
            },
        },
        .Union => |uni| .{
            .Union = .{
                .mutable = true,
                .isTagged = uni.isTagged,
                .tag = uni.tag,
                .name = uni.name,
                .fields = uni.fields,
                .definitions = uni.definitions,
                .scope = uni.scope,
            },
        },
        .Enum => |enm| .{
            .Enum = .{
                .mutable = true,
                .name = enm.name,
                .fields = enm.fields,
                .definitions = enm.definitions,
                .scope = enm.scope,
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
            const fields = uni.fields;

            var size: u32 = 0;
            for (fields) |field| {
                size = @max(size, self.sizeOf(field.valueType));
            }

            break :ret size + @as(u32, if (uni.isTagged) @sizeOf(u32) else 0);
        },
    };
}

pub fn tryGetDefinitionIndex(self: *Typechecker, from: TypeID, member: []const u8) Error!?defines.Offset {
    const decls = switch (self.typeTable.get(from)) {
        .Enum => |enm| enm.definitions,
        .Struct => |str| str.definitions,
        .Union => |uni| uni.definitions,
        else => {
            self.report("Definition index can only be used for structs, enums and unions. Received '{s}' instead.", .{
                self.typeName(self.arena.allocator(), from),
            });
            return error.IllegalSyntax;
        },
    };

    for (decls, 0..) |decl, index| {
        if (std.mem.eql(u8, decl.name, member)) {
            return @intCast(index);
        }
    }

    return null;
}

pub fn definitionIndex(self: *Typechecker, from: TypeID, member: []const u8) Error!defines.Offset {
    if (try self.tryGetDefinitionIndex(from, member)) |found| {
        return found;
    }

    self.report("Couldn't find definition '{s}' in type '{s}'.", .{
        member,
        self.typeName(self.arena.allocator(), from),
    });
    return error.MissingDefinition;
}

pub fn tryGetFieldIndex(self: *Typechecker, from: TypeID, fieldName: []const u8) Error!?defines.Offset {
    const fields = switch (self.typeTable.get(from)) {
        .Struct => |str| str.fields,
        .Union => |uni| uni.fields,
        .Enum => |enm| blk: {
            for (enm.fields, 0..) |field, index| {
                if (std.mem.eql(u8, field, fieldName)) {
                    return @intCast(index);
                }
            }

            break :blk &.{};
        },
        else => {
            self.report("Definition index can only be used for structs, enums and unions. Received '{s}' instead.", .{
                self.typeName(self.arena.allocator(), from),
            });
            return error.IllegalSyntax;
        },
    };

    for (fields, 0..) |field, index| {
        if (std.mem.eql(u8, field.name, fieldName)) {
            return @intCast(index);
        }
    }

    return null;
}

pub fn fieldIndex(self: *Typechecker, from: TypeID, fieldName: []const u8) Error!defines.Offset {
    if (try self.tryGetFieldIndex(from, fieldName)) |found| {
        return found;
    }

    self.report("Couldn't find field '{s}' in type '{s}'.", .{
        fieldName,
        self.typeName(self.arena.allocator(), from),
    });
    return error.MissingDefinition;
}

pub fn typeName(self: *const Typechecker, allocator: Allocator, typeID: TypeID) []const u8 {
    const typename = struct {
        fn typename(this: *const Typechecker, alc: Allocator, tid: TypeID) []const u8 {
            const prefix = if (this.mutable(tid)) "mut " else "";

            const name = switch (this.typeTable.get(tid)) {
                .Struct => |str| str.name,
                .Union => |uni| uni.name,
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

                for (0..func.argTypes.len) |index| {
                    res = std.fmt.allocPrint(allocator, "{s}{s}{s}", .{
                        res,
                        self.typeName(allocator, func.argTypes[index]),
                        if (index == func.argTypes.len - 1) "" else ", ",
                    }) catch return "AllocatorFailure";
                }


                res = std.fmt.allocPrint(allocator, "{s}) -> {s}", .{
                    res,
                    self.typeName(allocator, func.returnType),
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

pub fn determineExpected(maybeExpected: ?TypeID) ?TypeID {
    return
        if (maybeExpected) |expected|
            if (
                expected == Comptime.Builtin.Type("any")
                or expected == Comptime.Builtin.Type("mut any")
            ) null
            else expected
        else null;
}
