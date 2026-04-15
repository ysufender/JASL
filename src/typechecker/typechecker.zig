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
const Allocator = std.mem.Allocator;
const Arena = std.heap.ArenaAllocator;
const ResolutionKey = defines.ResolutionKey;

const deepCopy = collections.deepCopy;

pub const TypeTable = MultiArrayList(TypeInfo);
pub const TypeMap = defines.LookupMap(TypeInfo, TypeID);
pub const ResolutionMap = defines.ResolutionMap(TypeID);
pub const MetadataMap = defines.ResolutionMap([]const defines.ExpressionPtr);
const LookupMap = defines.LookupMap(defines.ExpressionPtr, TypecheckStatus);

const TypecheckStatus = struct {
    status: enum {
        Checked,
        InProgress,
        NotChecked,
    },
    type: TypeID,
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
metadata: MetadataMap,
reso: ResolutionMap,

executer: Comptime,

currentFile: defines.FilePtr,
lastToken: defines.TokenPtr,

scratch: std.ArrayList(u32),

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

    var typeTable = try TypeTable.init(allocator, counts.types * 3 + @as(u32, @intCast(builtins.len)));
    var reso = ResolutionMap.empty;
    var typeMap = TypeMap.empty;
    var metadata = MetadataMap.empty;

    reso.ensureTotalCapacity(allocator, counts.expressions) catch return error.AllocatorFailure;
    typeMap.ensureTotalCapacity(allocator, counts.types * 3 + @as(u32, @intCast(builtins.len))) catch return error.AllocatorFailure;
    metadata.ensureTotalCapacity(allocator, counts.meta * 3) catch return error.AllocatorFailure;

    inline for (builtins, 0..) |builtin, id| {
        typeTable.appendAssumeCapacity(std.meta.activeTag(builtin), @field(builtin, @tagName(std.meta.activeTag(builtin))));
        typeMap.putAssumeCapacityNoClobber(.{ .name = builtin, .scope = 0 }, @intCast(id));
    }

    return .{
        .context = context,
        .modules = modules,
        .typeTable = typeTable,
        .reso = reso,
        .typeMap = typeMap,
        .metadata = metadata,
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
        .scratch = @FieldType(Typechecker, "scratch").initCapacity(allocator, 128) catch return error.AllocatorFailure,
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

    _ = try self.typecheckDecl(self.symbols.lookup.get(.{ .scope = 1, .name = "main" }).?);

    return .{
        .types = try deepCopy(self.typeTable.slice(), allocator), 
        .resolutionMap = try deepCopy(self.reso, allocator),
        .constants = try deepCopy(self.constants, allocator),
    };
}

pub fn typecheckStatement(self: *Typechecker, statementPtr: defines.StatementPtr) Error!void {
    const allocator = self.arena.allocator();
    const ast = self.context.getAST(self.currentFile);
    const tokens = self.context.getTokens(self.currentFile);
    _ = allocator;
    _ = tokens;

    const statement = ast.statements.get(statementPtr);
    switch (statement.type) {
        .VariableDefinition => {
            const exprPtr = ast.extra.items[statement.value + 2];
            const initializer = try self.typecheckExpression(exprPtr);

            const signatures = defines.Range{
                .start = ast.extra.items[statement.value],
                .end = ast.extra.items[statement.value + 1],
            };

            const initializerCount = initializer.start-initializer.end;
            const signatureCount = signatures.start-signatures.end;
            if (signatureCount != initializerCount) {
                self.report(
                    "Expression count mismatch in variable definition."
                    ++ "\n\tExpected {d} expressions, received {d}.", .{
                        signatureCount,
                        initializerCount
                });
                return error.IllegalSyntax;
            }

            for (signatures.start..signatures.end) |signaturePtrPtr| {
                const signaturePtr = ast.extra.items[signaturePtrPtr];
                self.lastToken = ast.signatures.items(.name)[signaturePtr];
                const declTypePtr: defines.ExpressionPtr = ast.signatures.items(.type)[signaturePtr];
                const declType = try self.typecheckExpression(declTypePtr);

                switch (declType.start - declType.end) {
                    1 => { },
                    0 => {
                        self.report("Untyped declarations are not supported.", .{});
                        return error.IllegalSyntax;
                    },
                    else => {
                        self.report("Multi-typed declarations are not supported.", .{});
                        return error.IllegalSyntax;
                    },
                }

                const declIndex = @as(u32, @intCast(signaturePtrPtr)) - signatures.start;
                _ = declIndex;
            } 
        },
        else => {
            self.report("Typechecking is not implemented for {s}", .{@tagName(statement.type)});
            return error.NotImplemented;
        },
    }
}

pub fn typecheckExpression(self: *Typechecker, expressionPtr: defines.ExpressionPtr) Error!defines.Range {
    const allocator = self.arena.allocator();
    const ast = self.context.getAST(self.currentFile);
    const tokens = self.context.getTokens(self.currentFile);

    _ = tokens;
    _ = allocator;

    const expr = ast.expressions.get(expressionPtr);
    // TODO:
    return switch (expr.type) {
        .Literal => .{
            .start = 0,
            .end = 0,
        },
        .ValueType => { },
        else => {
            self.report("Typechecking is not implemented for {s}", .{@tagName(expr.type)});
            return error.NotImplemented;
        },
    };
}

pub fn typecheckDecl(self: *Typechecker, declPtr: defines.DeclPtr) Error!defines.Range {
    const decl = self.symbols.declarations.get(declPtr);

    return blk: switch (decl.kind) {
        .Variable => {
            self.lastToken = decl.token;
            break :blk self.typecheckExpression(decl.node);
        },
        else => {
            self.report("Typechecking is not implemented for {s}", .{@tagName(decl.kind)});
            return error.NotImplemented;
        },
    };
}

pub fn suitable(forThis: TypeID, this: TypeID) bool {
    _ = forThis;
    _ = this;
    return false;
}

fn report(self: *Typechecker, comptime fmt: []const u8, args: anytype) void {
    common.log.err(fmt, args);
    const token = self.context.getTokens(self.currentFile).get(self.lastToken);
    const position = token.position(self.context, self.currentFile);
    common.log.err("\t{s} {d}:{d}\n", .{ self.context.getFileName(self.currentFile), position.line, position.column});
}

const builtins = [_]TypeInfo{
    .{ // u32
        .Integer = .{
            .mutable = false,
            .size = 32,
            .signed = false,
        }
    },
    .{ // i32
        .Integer = .{
            .mutable = false,
            .size = 32,
            .signed = true,
        }
    },
    .{ // mut u32
        .Integer = .{
            .mutable = true,
            .size = 32,
            .signed = false,
        }
    },
    .{ // mut i32
        .Integer = .{
            .mutable = true,
            .size = 32,
            .signed = true,
        }
    },
    .{ // u8
        .Integer = .{
            .mutable = false,
            .size = 8,
            .signed = false,
        }
    },
    .{ // i8
        .Integer = .{
            .mutable = false,
            .size = 8,
            .signed = true,
        }
    },
    .{ // mut u8
        .Integer = .{
            .mutable = true,
            .size = 8,
            .signed = false,
        }
    },
    .{ // mut i8
        .Integer = .{
            .mutable = true,
            .size = 8,
            .signed = true,
        }
    },
    .{ // bool
        .Bool = false 
    },
    .{ // mut bool
        .Bool = true
    },
    .{ // flaot
        .Float = false 
    },
    .{ // mut float
        .Float = true
    },
    .{ // void
        .Void = {},
    },
    .{ // type
       .Type = 12,
    },
    .{ // noreturn
        .Noreturn = { },
    },
};
