// TODO: remove all temp arraylists, use scratch
// TODO: assert certain semantic checks as well (like only calls on defer)

const std = @import("std");
const common = @import("../core/common.zig");
const lexer = @import("../lexer/lexer.zig");
const arraylist = @import("../util/arraylist.zig");
const types = @import("../core/types.zig");

const Allocator = std.mem.Allocator;
const ExpressionResult = common.CompilerError!types.ExpressionPtr;

pub const StatementResult = common.CompilerError!types.StatementPtr;

pub const VariableSignatureMap = arraylist.MultiArrayList(VariableSignature);
pub const ExpressionMap = arraylist.MultiArrayList(Expression);
pub const StatementMap = arraylist.MultiArrayList(Statement);

// Because manually tagged unions are more
// performant with arraylist.MultiArrayList(T)
pub const Expression = struct {
    pub const Type = enum {
        Assignment,
        Binary, // ok
        Literal, // ok
        Indexing, // ok
        Identifier, // ok
        Unary, // ok
        StructDefinition, // ok
        EnumDefinition,
        UnionDefinition,
        FunctionDefinition, // ok
        Call, // ok
        Conditional, // ok
        MutableType, // ok
        PointerType, // ok
        SliceType, // ok
        FunctionType, // ok
        ValueType, // ok
        Scoping, // ok
        ExpressionList,
        Dot, // ok
    };

    type: Type,
    value: types.OpaquePtr,
};

// Because manually tagged unions are more
// performant with arraylist.MultiArrayList(T)
pub const Statement = struct {
    pub const Type = enum {
        Block, // ok
        InlineAssembly, // ok
        Return, // ok
        Conditional, // ok
        While, // ok
        Break, // ok
        Continue, // ok
        VariableDefinition, // ok
        Discard, // ok
        Import, // ok
        Expression, // ok
        Defer,
    };

    type: Type,
    value: types.OpaquePtr,
};

pub const VariableSignature = struct {
    public: bool,
    name: types.TokenPtr,
    type: types.ExpressionPtr,
};

pub const AST = struct {
    const Self = @This();

    tokens: *const lexer.TokenList.Slice,
    expressions: ExpressionMap.Slice,
    statements: StatementMap.Slice,
    signatures: VariableSignatureMap.Slice,
    statementMask: std.ArrayList(types.StatementPtr).Slice,
    extra: std.ArrayList(types.OpaquePtr).Slice,

    pub fn dupe(self: *const Self, allocator: Allocator) common.CompilerError!Self {
        return .{
            .tokens = self.tokens,
            .expressions = try self.expressions.dupe(allocator),
            .statements = try self.statements.dupe(allocator),
            .signatures = try self.signatures.dupe(allocator),
            .statementMask = allocator.dupe(types.StatementPtr, self.statementMask) catch return error.AllocatorFailure,
            .extra = allocator.dupe(types.OpaquePtr, self.extra) catch return error.AllocatorFailure,
        };
    }

    pub fn eql(self: *const Self, other: *const Self) bool {
        return
            self.tokens.eql(other.tokens)
            and self.expressions.eql(&other.expressions)
            and self.statements.eql(&other.statements)
            and self.signatures.eql(&other.signatures)
            and std.mem.eql(types.StatementPtr, self.statementMask, other.statementMask)
            and std.mem.eql(types.OpaquePtr, self.extra, other.extra);
    }

    pub fn print(self: *const Self) void {
        std.debug.print("\nTokens:      ", .{});
        var titerator = self.tokens.iterator();
        while (titerator.next()) |token| {
            std.debug.print("{d} ", .{token.start});
        }
        std.debug.print("\nExpressions: ", .{});
        var eiterator = self.expressions.iterator();
        while (eiterator.next()) |stmt| {
            std.debug.print("{d} ", .{stmt.value});
        }
        std.debug.print("\nStatements:  ", .{});
        var siterator = self.statements.iterator();
        while (siterator.next()) |stmt| {
            std.debug.print("{d} ", .{stmt.value});
        }
        std.debug.print("\nSignatures:  ", .{});
        var viterator = self.signatures.iterator();
        while (viterator.next()) |stmt| {
            std.debug.print("{d} ", .{stmt.name});
        }
        std.debug.print("\nMask:        ", .{});
        for (self.statementMask) |stmt| {
            std.debug.print("{d} ", .{stmt});
        }
        std.debug.print("\nExtra:       ", .{});
        for (self.extra) |extra| {
            std.debug.print("{d} ", .{extra});
        }
        std.debug.print("\n", .{});
    }
};

pub const Parser = struct {
    const Self = @This();

    tokens: *const lexer.TokenList.Slice,
    current: types.TokenPtr,

    arena: std.heap.ArenaAllocator,

    expressionMap: ExpressionMap,
    statementMap: StatementMap,
    signaturePool: VariableSignatureMap,

    statementMask: std.ArrayList(types.StatementPtr),

    extra: std.ArrayList(types.OpaquePtr),
    scratch: std.ArrayList(types.OpaquePtr),

    file: types.FilePtr,
    context: *common.CompilerContext,

    pub fn init(base: Allocator, context: *common.CompilerContext, tokensPtr: types.TokenListPtr) common.CompilerError!Parser {
        var arena = std.heap.ArenaAllocator.init(base);
        const tokens = context.getTokens(tokensPtr);

        return .{
            .signaturePool = try VariableSignatureMap.init(arena.allocator(), tokens.len / 2),
            .expressionMap = try ExpressionMap.init(arena.allocator(), tokens.len / 2),
            .statementMap = try StatementMap.init(arena.allocator(), tokens.len / 4),
            .statementMask = std.ArrayList(types.StatementPtr).initCapacity(arena.allocator(), tokens.len / 4) catch return error.AllocatorFailure,
            .file = tokens.items(.start)[0],
            .context = context,
            .tokens = tokens,
            .current = 1,
            .arena = arena,
            .extra = std.ArrayList(types.OpaquePtr).initCapacity(arena.allocator(), tokens.len) catch return error.AllocatorFailure,
            .scratch = std.ArrayList(types.OpaquePtr).initCapacity(arena.allocator(), 128) catch return error.AllocatorFailure,
        };
    }

    /// Returns a final table containing all info about the parsing.
    /// Parser is undefined and should be reinitialized after the call.
    pub fn parse(self: *Self) common.CompilerError!types.ASTPtr {
        defer self.arena.deinit();

        // any type
        self.expressionMap.appendAssumeCapacity(.{
            .type = .ValueType,
            .value = 0,
        });

        var errCount: types.OpaquePtr = 0;
        var lastErr: common.CompilerError = undefined;

        while (!self.isAtEnd()) {
            if (self.statement()) |index| {
                self.statementMask.append(self.allocator(), index) catch return error.AllocatorFailure;
            }
            else |err| {
                errCount += 1;
                lastErr = err;
                common.log.err("Error: {d} <{s}>\n", .{ @intFromError(err), @errorName(err) });
                self.synchronize();
                if (errCount == self.context.settings.maxErr) {
                    common.log.err("Too many errors, aborting compilation.", .{});
                    return err;
                }
            }
        }

        if (errCount > 1) {
            lastErr = error.MultipleErrors;
        }

        if (errCount > 0) {
            return lastErr;
        }

        const ast = AST{
            .tokens = self.tokens,
            .expressions = self.expressionMap.slice(),
            .statements = self.statementMap.slice(),
            .signatures = self.signaturePool.slice(),
            .statementMask = self.statementMask.items,
            .extra = self.extra.items,
        };

        const result = try self.context.registerAST(ast);
        //std.debug.print("\nParse", .{});
        //ast.print();
        return result;
    }

    //
    // Statements
    //

    fn statement(self: *Self) StatementResult {
        return switch (self.tokens.items(.type)[self.advance()]) {
            .LBrace => self.block(),
            .Asm => self.inlineAssembly(),
            .If => self.conditional(),
            .While => self.whileStatement(),
            .Return => self.returnStatement(),
            .Break => self.breakStatement(),
            .Continue => self.continueStatement(),
            .Pub => switch (self.tokens.items(.type)[self.advance()]) {
                .Let => self.variable(true),
                else => {
                    self.report("Expected a variable definition after 'pub' specifier.", .{});
                    return error.InvalidToken;
                },
            },
            .Let => self.variable(false),
            .Discard => self.discard(),
            .Import => self.import(),
            .Semicolon => self.statement(),
            .Defer => self.deferStatement(),
            .Extern => {
                self.report("Extern symbols are not yet implemented.", .{});
                return error.Unimplemented;
            },
            else => self.expressionStmt(),
        };
    }

    /// Defer only allows function calls, for now.
    fn deferStatement(self: *Self) StatementResult {
        const call = try self.expression();

        if (self.expressionMap.items(.type)[call] != .Call) {
            self.report("Only function calls are allowed in defer statements.", .{});
            return error.IllegalSyntax;
        }

        _ = try self.consume(.Semicolon, error.MissingSemicolon, "Expected semicolon after statement.");

        const result = try self.alloc(Statement);
        self.statementMap.set(result, .{
            .type = .Defer,
            .value = call,
        });

        return result;
    }

    fn expressionStmt(self: *Self) StatementResult {
        self.current -= 1;
        const expr = try self.expression();

        switch (self.expressionMap.items(.type)[expr]) {
            .Assignment, .Call => { },
            else => {
                self.report("Only assignment and function calls are allowed as expression statements.", .{});
                return error.IllegalSyntax;
            },
        }

        _ = try self.consume(.Semicolon, error.MissingSemicolon, "Expected semicolon after statement.");

        const result = try self.alloc(Statement);
        self.statementMap.set(result, .{
            .type = .Expression,
            .value = expr,
        });

        return result;
    }

    fn block(self: *Self) StatementResult {
        const scratchStart = self.scratch.items.len;
        while (!self.check(.RBrace)) {
            self.scratch.append(self.allocator(), try self.statement()) catch return error.AllocatorFailure;
        }

        _ = try self.consume(.RBrace, error.MissingBrace, "Missing enclosing brace '}' after block.");
        const stmts = try self.commitScratch(scratchStart);

        const start: types.OpaquePtr = @intCast(self.extra.items.len);
        self.extra.append(self.allocator(), stmts.start) catch return error.AllocatorFailure;
        self.extra.append(self.allocator(), stmts.end) catch return error.AllocatorFailure;

        const result = try self.alloc(Statement);
        self.statementMap.set(result, .{
            .type = .Block,
            .value = start,
        });

        return result;
    }

    fn inlineAssembly(self: *Self) StatementResult {
        const asmly = (try self.consume(.String, error.MissingBrace, "Expected block after 'asm' statement."));

        const result = try self.alloc(Statement);
        self.statementMap.set(result, .{
            .type = .InlineAssembly,
            .value = asmly,
        });

        _ = try self.consume(.Semicolon, error.MissingSemicolon, "Expected semicolon after statement.");

        return result;
    }

    fn returnStatement(self: *Self) StatementResult {
        const expr = try self.expression();
        _ = try self.consume(.Semicolon, error.MissingSemicolon, "Expected semicolon after statement.");
        
        const result = try self.alloc(Statement);
        self.statementMap.set(result, .{
            .type = .Return,
            .value = expr
        });
        
        return result;
    }

    fn conditional(self: *Self) StatementResult {
        const condition = try self.expression();

        if (!self.check(.LBrace)) {
            self.report("Expected a block after if statement.", .{});
            return error.MissingBrace;
        }

        const body = try self.statement();

        var otherwise: ?types.StatementPtr = null;
        if (self.match(&.{.Else})) {
            switch (self.tokens.items(.type)[self.peek()]) {
                .LBrace, .If => { },
                else => {
                    self.report("Expected a block or conditional after else statement.", .{});
                    return error.MissingBrace;
                },
            }

            otherwise.? = try self.statement();
        }

        const start: types.OpaquePtr = @intCast(self.extra.items.len);
        self.extra.append(self.allocator(), condition) catch return error.AllocatorFailure;
        self.extra.append(self.allocator(), body) catch return error.AllocatorFailure;
        self.extra.append(self.allocator(), if (otherwise) |_| 1 else 0) catch return error.AllocatorFailure;
        if (otherwise) |val| {
            self.extra.append(self.allocator(), val) catch return error.AllocatorFailure;
        }

        const result = try self.alloc(Statement);
        self.statementMap.set(result, .{
            .type = .Conditional,
            .value = start,
        });

        return result;
    }

    fn whileStatement(self: *Self) StatementResult {
        const condition = try self.expression();

        if (!self.check(.LBrace)) {
            self.report("Expected a while body.", .{});
            return error.MissingBrace;
        }

        const body = try self.statement();

        const start: types.OpaquePtr = @intCast(self.extra.items.len);
        self.extra.append(self.allocator(), condition) catch return error.AllocatorFailure;
        self.extra.append(self.allocator(), body) catch return error.AllocatorFailure;
        
        const result = try self.alloc(Statement);
        self.statementMap.set(result, .{
            .type = .While,
            .value = start,
        });
        
        return result;
    }

    fn breakStatement(self: *Self) StatementResult {
        _ = try self.consume(.Semicolon, error.MissingSemicolon, "Expected semicolon after statement.");
        const result = try self.alloc(Statement);
        self.statementMap.set(result, .{
            .type = .Break,
            .value = 0
        });
        return result;
    }

    fn continueStatement(self: *Self) StatementResult {
        _ = try self.consume(.Semicolon, error.MissingSemicolon, "Expected semicolon after statement.");
        const result = try self.alloc(Statement);
        self.statementMap.set(result, .{
            .type = .Continue,
            .value = 0
        });
        return result;
    }

    fn variable(self: *Self, public: bool) StatementResult {
        const sigsStart = self.scratch.items.len;
        while (!self.check(.Equal)) {
            self.scratch.append(self.allocator(), try self.variableSignature(public, false)) catch return error.AllocatorFailure;
            if (!self.match(&.{.Comma})) break;
        }

        if (sigsStart == self.scratch.items.len){
            self.report("Expected variable signature(s) after 'let'.", .{});
            return error.MissingIdentifier;
        }

        const signatures = try self.commitScratch(sigsStart);

        _ = try self.consume(.Equal, error.MissingAssignment, "Expected assignment in variable definition.");
        const expr = try self.expression();
        _ = try self.consume(.Semicolon, error.MissingSemicolon, "Expected semicolon after statement.");

        const start: types.OpaquePtr = @intCast(self.extra.items.len);
        self.extra.append(self.allocator(), signatures.start) catch return error.AllocatorFailure;
        self.extra.append(self.allocator(), signatures.end) catch return error.AllocatorFailure;
        self.extra.append(self.allocator(), expr) catch return error.AllocatorFailure;


        const result = try self.alloc(Statement);
        self.statementMap.set(result, .{
            .type = .VariableDefinition,
            .value = start,
        });

        return result;
    }

    fn discard(self: *Self) StatementResult {
        _ = try self.consume(.Equal, error.MissingAssignment, "Expected an assignment after discard.");
        const expr = try self.expression();
        _ = try self.consume(.Semicolon, error.MissingSemicolon, "Expected semicolon after statement.");

        const result = try self.alloc(Statement);
        self.statementMap.set(result, .{
            .type = .Discard,
            .value = expr
        });
        
        return result;
    }

    fn import(self: *Self) StatementResult {
        // const file = try self.consume(.String, error.InvalidToken, "Expected file path in import statement.");
        const module = try self.scoping();
        _ = try self.consume(.Semicolon, error.MissingSemicolon, "Expected semicolon after statement.");

        const result = try self.alloc(Statement);
        self.statementMap.set(result, .{
            .type = .Import,
            .value = module,
        });

        return result;
    }

    //
    // Expressions
    //

    fn expression(self: *Self) ExpressionResult {
        return self.assignment();
    }

    fn assignment(self: *Self) ExpressionResult {
        var expr = try self.ifExpression();

        if (self.match(&.{.Equal})) {
            const rhs = try self.ifExpression();

            const start: types.OpaquePtr = @intCast(self.extra.items.len);
            self.extra.append(self.allocator(), expr) catch return error.AllocatorFailure;
            self.extra.append(self.allocator(), rhs) catch return error.AllocatorFailure;

            const newExpr = try self.alloc(Expression);
            self.expressionMap.set(newExpr, .{
                .type = .Assignment,
                .value = start,
            });

            expr = newExpr;
        }

        return expr;
    }

    fn ifExpression(self: *Self) ExpressionResult {
        if (!self.match(&.{.If})) {
            return self.logicalOr();
        }

        const condition = try self.expression();
        const then = try self.expression();

        _ = try self.consume(.Else, error.MissingBranch, "Expected an 'else' branch in conditional expression.");
        const otherwise = try self.expression();

        const start: types.OpaquePtr = @intCast(self.extra.items.len);
        self.extra.append(self.allocator(), condition) catch return error.AllocatorFailure;
        self.extra.append(self.allocator(), then) catch return error.AllocatorFailure;
        self.extra.append(self.allocator(), otherwise) catch return error.AllocatorFailure;

        const expr = try self.alloc(Expression);
        self.expressionMap.set(expr, .{
            .type = .Conditional,
            .value = start,
        });

        return expr;
    }

    fn logicalOr(self: *Self) ExpressionResult {
        var expr = try self.logicalAnd();

        while (self.match(&.{.Or})) {
            expr = try self.commonBinary(expr, Self.logicalAnd);
        }

        return expr;
    }

    fn logicalAnd(self: *Self) ExpressionResult {
        var expr = try self.equality();

        while (self.match(&.{.And})) {
            expr = try self.commonBinary(expr, Self.equality);
        }

        return expr;
    }

    fn equality(self: *Self) ExpressionResult {
        var expr = try self.bitwiseOr();

        while (self.match(&.{.EqualEqual, .BangEqual})) {
            expr = try self.commonBinary(expr, Self.bitwiseOr);
        }

        return expr;
    }

    fn bitwiseOr(self: *Self) ExpressionResult {
        var expr = try self.bitwiseXor();

        while (self.match(&.{.Pipe})) {
            expr = try self.commonBinary(expr, Self.bitwiseXor);
        }

        return expr;
    }

    fn bitwiseXor(self: *Self) ExpressionResult {
        var expr = try self.bitwiseAnd();

        while (self.match(&.{.Xor})) {
            expr = try self.commonBinary(expr, Self.bitwiseAnd);
        }

        return expr;
    }

    fn bitwiseAnd(self: *Self) ExpressionResult {
        var expr = try self.comparison();

        while (self.match(&.{.Ampersand})) {
            expr = try self.commonBinary(expr, Self.comparison);
        }

        return expr;
    }

    fn comparison(self: *Self) ExpressionResult {
        var expr = try self.shift();

        while (self.match(&.{.Lesser, .LesserEqual, .Greater, .GreaterEqual})) {
            expr = try self.commonBinary(expr, Self.shift);
        }

        return expr;
    }

    fn shift(self: *Self) ExpressionResult {
        var expr = try self.term();

        while (self.match(&.{.RightShift, .LeftShift})) {
            expr = try self.commonBinary(expr, Self.term);
        }

        return expr;
    }

    fn term(self: *Self) ExpressionResult {
        var expr = try self.factor();

        while (self.match(&.{.Plus, .Minus})) {
            expr = try self.commonBinary(expr, Self.factor);
        }

        return expr;
    }

    fn factor(self: *Self) ExpressionResult {
        var expr = try self.unary();

        while (self.match(&.{.Slash, .Star})) {
            expr = try self.commonBinary(expr, Self.unary);
        }

        return expr;
    }

    fn unary(self: *Self) ExpressionResult {
        if (self.match(&.{.Bang, .Minus, .Plus, .Tilde})) {
            const operator = self.tokens.items(.type)[self.previous()];

            const rhs = try self.unary();

            const start: types.OpaquePtr = @intCast(self.extra.items.len);
            self.extra.append(self.allocator(), @intFromEnum(operator)) catch return error.AllocatorFailure;
            self.extra.append(self.allocator(), rhs) catch return error.AllocatorFailure;

            const expr = try self.alloc(Expression);
            self.expressionMap.set(expr, .{
                .type = .Unary,
                .value = start,
            });

            return expr;
        }

        return self.postfix();
    }

    fn postfix(self: *Self) ExpressionResult {
        var expr = try self.primary();

        while (true) {
            if (self.match(&.{.LParen})) {
                const argsStart = self.scratch.items.len;
                while (!self.check(.RParen)) {
                    self.scratch.append(self.allocator(), try self.expression()) catch return error.AllocatorFailure;
                    if (!self.match(&.{.Comma})) {
                        break;
                    }
                }
                _ = try self.consume(.RParen, error.MissingParenthesis, "Expected closing parenthesis ')' in function call.");
                const args = try self.commitScratch(argsStart);

                const start: types.OpaquePtr = @intCast(self.extra.items.len);
                self.extra.append(self.allocator(), expr) catch return error.AllocatorFailure;
                self.extra.append(self.allocator(), args.start) catch return error.AllocatorFailure;
                self.extra.append(self.allocator(), args.end) catch return error.AllocatorFailure;

                const newExpr = try self.alloc(Expression);
                self.expressionMap.set(newExpr, .{
                    .type = .Call,
                    .value = start,
                });
                expr = newExpr;
            } else if (self.match(&.{.Dot})) {
                if (!self.match(&.{.Identifier, .Ampersand, .Star})) {
                    _ = self.advance();
                    self.report("Expected a member name in dot expression.", .{});
                    return error.MissingIdentifier;
                }

                const member = self.previous();

                const start: types.OpaquePtr = @intCast(self.extra.items.len);
                self.extra.append(self.allocator(), expr) catch return error.AllocatorFailure;
                self.extra.append(self.allocator(), member) catch return error.AllocatorFailure;

                const newExpr = try self.alloc(Expression);
                self.expressionMap.set(newExpr, .{
                    .type = .Dot,
                    .value = start,
                });
                expr = newExpr;
            } else if (self.match(&.{.LBracket})) {
                const index = try self.expression();
                _ = try self.consume(.RBracket, error.MissingBracket, "Expected closing bracket ']'.");

                const start: types.OpaquePtr = @intCast(self.extra.items.len);
                self.extra.append(self.allocator(), expr) catch return error.AllocatorFailure;
                self.extra.append(self.allocator(), index) catch return error.AllocatorFailure;

                const newExpr = try self.alloc(Expression);
                self.expressionMap.set(newExpr, .{
                    .type = .Indexing,
                    .value = start,
                });
                expr = newExpr;
            } else {
                break;
            }
        }

        return expr;
    }

    fn primary(self: *Self) ExpressionResult {
        switch (self.tokens.items(.type)[self.peek()]) {
            .False, .True, .Null, .Integer, .Float, .String => {
                const expr = try self.alloc(Expression);
                self.expressionMap.set(expr, .{
                    .type = .Literal,
                    .value = self.advance(),
                });
                return expr;
            },
            .Mut, .Star, .LBracket,
            .Enum, .Struct, .Union => return self.typeExpression(),
            .Fn => return self.function(),
            .LParen => {
                _ = self.advance();

                const exprsStart = self.scratch.items.len;
                while (!self.check(.RParen)) {
                    self.scratch.append(self.allocator(), try self.expression()) catch return error.AllocatorFailure;
                    if (!self.match(&.{.Comma})) {
                        break;
                    }
                }

                _ = try self.consume(.RParen, error.MissingBrace, "Expected enclosing parenthesis ')' in expression list.");
                const expressions = try self.commitScratch(exprsStart);

                const start: types.OpaquePtr = @intCast(self.extra.items.len);
                self.extra.append(self.allocator(), expressions.start) catch return error.AllocatorFailure;
                self.extra.append(self.allocator(), expressions.end) catch return error.AllocatorFailure;

                const expr = try self.alloc(Expression);
                self.expressionMap.set(expr, .{
                    .type = .ExpressionList,
                    .value = start,
                });
                return expr;
            },
            .Identifier => return self.scoping(),
            else => {
                self.report("Expected a primary expression, got '{s}' instead.", .{self.tokens.get(self.advance()).lexeme(self.context, self.file)});
                return error.InvalidToken;
            },
        }
    }

    fn scoping(self: *Self) ExpressionResult {
        var expr = try self.alloc(Expression);
        self.expressionMap.set(expr, .{
            .type = .Identifier,
            .value = try self.consume(.Identifier, error.MissingIdentifier, "Expected identifier in scoping expression"),
        });

        while (self.match(&.{.DoubleColon})) {
            const member = try self.consume(.Identifier, error.MissingIdentifier, "Expected member name in scope resolution.");
            
            const start: types.OpaquePtr = @intCast(self.extra.items.len);
            self.extra.append(self.allocator(), expr) catch return error.AllocatorFailure;
            self.extra.append(self.allocator(), member) catch return error.AllocatorFailure;

            const newExpr = try self.alloc(Expression);
            // std.debug.print("Scoping Def {d}\n", .{newExpr});
            // std.debug.print("Scoping Def Start {d}\n", .{start});
            // std.debug.print("Scoping Def LHS {d} {d}\n", .{self.extra.items[start], expr});
            // std.debug.print("Scoping Def Member {d} {d}\n", .{self.extra.items[start + 1], member});
            self.expressionMap.set(newExpr, .{
                .type = .Scoping,
                .value = start,
            });
            expr = newExpr;
        }

        return expr;
    }

    fn function(self: *Self) ExpressionResult {
        _ = self.advance();
        _ = try self.consume(.LParen, error.MissingParenthesis, "Expected a parameter list in function definition.");
        
        const paramsStart = self.scratch.items.len;
        while (!self.check(.RParen)) {
            self.scratch.append(self.allocator(), try self.variableSignature(false, true)) catch return error.AllocatorFailure;
            if (!self.match(&.{.Comma})) {
                break;
            }
        }
        _ = try self.consume(.RParen, error.MissingParenthesis, "Expected closing parenthesis ')' after parameter list.");
        const params = try self.commitScratch(paramsStart);

        _ = try self.consume(.Arrow, error.MissingArrow, "Expected arrow '->' to denote return type.");
        const returns = try self.ifExpression();

        _ = try self.consume(.LBrace, error.MissingBrace, "Expected function body.");
        self.current -= 1;
        const body = try self.statement();

        const start: types.OpaquePtr = @intCast(self.extra.items.len);
        self.extra.append(self.allocator(), params.start) catch return error.AllocatorFailure;
        self.extra.append(self.allocator(), params.end) catch return error.AllocatorFailure;
        self.extra.append(self.allocator(), returns) catch return error.AllocatorFailure;
        self.extra.append(self.allocator(), body) catch return error.AllocatorFailure;

        const expr = try self.alloc(Expression);
        self.expressionMap.set(expr, .{
            .type = .FunctionDefinition,
            .value = start,
        });

        return expr;
    }

    fn structDefinition(self: *Self) ExpressionResult {
        _ = try self.consume(.LBrace, error.MissingBrace, "Expected struct body.");

        // Check unionDefinition for details.
        // TODO: Fix this.
        // TODO: Maybe two loops using scratch would be better...
        // var variablesTmp = std.ArrayList(types.OpaquePtr).initCapacity(self.allocator(), 5) catch return error.AllocatorFailure;
        // var definitions = std.ArrayList(types.OpaquePtr).initCapacity(self.allocator(), 5) catch return error.AllocatorFailure;
        var variablesTmp = arraylist.ReverseStackArray(types.OpaquePtr, 512).init();
        var definitions = arraylist.ReverseStackArray(types.OpaquePtr, 512).init();

        while (!self.check(.RBrace)) {
            switch (self.tokens.items(.type)[self.peek()]) {
                .Pub => {
                    _ = self.advance();
                    switch (self.tokens.items(.type)[self.peek()]) {
                        .Let => {
                            _ = self.advance();
                            try definitions.append(try self.variable(true));
                        },
                        .Identifier => {
                            try variablesTmp.append(try self.variableSignature(true, true));
                            if (!self.match(&.{.Comma})) break;
                        },
                        else => {
                            _ = self.advance();
                            self.report("Expected a field after 'pub' specifier.", .{});
                            return error.InvalidToken;
                        },
                    }
                },
                .Let => {
                    _ = self.advance();
                    try definitions.append(try self.variable(false));
                },
                .Identifier => {
                    try variablesTmp.append(try self.variableSignature(false, true));
                    if (!self.match(&.{.Comma})) break;
                },
                else => {
                    _ = self.advance();
                    self.report("Expected a field in struct definition.", .{});
                    return error.InvalidToken;
                },
            }
        }

        _ = try self.consume(.RBrace, error.MissingBrace, "Expected enclosing brace after struct definition.");

        const variables = try self.commitFromSlice(variablesTmp.items);
        const defs = try self.commitFromSlice(definitions.items);

        const start: types.OpaquePtr = @intCast(self.extra.items.len);
        self.extra.append(self.allocator(), variables.start) catch return error.AllocatorFailure;
        self.extra.append(self.allocator(), variables.end) catch return error.AllocatorFailure;
        self.extra.append(self.allocator(), defs.start) catch return error.AllocatorFailure;
        self.extra.append(self.allocator(), defs.end) catch return error.AllocatorFailure;

        const expr = try self.alloc(Expression);
        self.expressionMap.set(expr, .{
            .type = .StructDefinition,
            .value = start,
        });

        return expr;
    }

    fn enumDefinition(self: *Self) ExpressionResult {
        _ = try self.consume(.LBrace, error.MissingBrace, "Expected enum body.");

        // Check unionDefinition for details.
        // TODO: Fix this.
        var variablesTmp = arraylist.ReverseStackArray(types.OpaquePtr, 512).init();
        var definitions = arraylist.ReverseStackArray(types.OpaquePtr, 512).init();

        while (!self.check(.RBrace)) {
            switch (self.tokens.items(.type)[self.peek()]) {
                .Pub => {
                    _ = self.advance();
                    switch (self.tokens.items(.type)[self.peek()]) {
                        .Let => {
                            _ = self.advance();
                            try definitions.append(try self.variable(true));
                        },
                        else => {
                            _ = self.advance();
                            self.report("Expected a definition after 'pub' specifier.", .{});
                            return error.InvalidToken;
                        },
                    }
                },
                .Let => {
                    _ = self.advance();
                    try definitions.append(try self.variable(false));
                },
                .Identifier => {
                    try variablesTmp.append(self.advance());
                    if (!self.match(&.{.Comma})) break;
                },
                else => {
                    _ = self.advance();
                    self.report("Expected a field in enum definition.", .{});
                    return error.InvalidToken;
                },
            }
        }

        _ = try self.consume(.RBrace, error.MissingBrace, "Expected enclosing brace after enum definition.");

        const variables = try self.commitFromSlice(variablesTmp.items);
        const defs = try self.commitFromSlice(definitions.items);

        const start: types.OpaquePtr = @intCast(self.extra.items.len);
        self.extra.append(self.allocator(), variables.start) catch return error.AllocatorFailure;
        self.extra.append(self.allocator(), variables.end) catch return error.AllocatorFailure;
        self.extra.append(self.allocator(), defs.start) catch return error.AllocatorFailure;
        self.extra.append(self.allocator(), defs.end) catch return error.AllocatorFailure;

        const expr = try self.alloc(Expression);
        self.expressionMap.set(expr, .{
            .type = .EnumDefinition,
            .value = start,
        });

        return expr;
    }

    fn unionDefinition(self: *Self) ExpressionResult {
        var tagged: u32 = 0;
        var tag: ?types.ExpressionPtr = null;

        if (self.match(&.{.LParen})) {
            tagged = 1;
            if (!self.match(&.{.Enum})) {
                tag = try self.ifExpression();
            }
            _ = try self.consume(.RParen, error.MissingParenthesis, "Expected closing parenthesis.");
        }

        _ = try self.consume(.LBrace, error.MissingBrace, "Expected union body.");

        // For some reason, variablesTmp overwrites the extra buffer.
        // Fixed buffer for temporary fix.
        // TODO: fix this
        var variablesTmp = arraylist.ReverseStackArray(types.OpaquePtr, 512).init();
        var definitions = arraylist.ReverseStackArray(types.OpaquePtr, 512).init();

        while (!self.check(.RBrace)) {
            switch (self.tokens.items(.type)[self.peek()]) {
                .Pub => {
                    _ = self.advance();
                    switch (self.tokens.items(.type)[self.peek()]) {
                        .Let => {
                            _ = self.advance();
                            try definitions.append(try self.variable(true));
                        },
                        else => {
                            _ = self.advance();
                            self.report("Expected a definition after 'pub' specifier.", .{});
                            return error.InvalidToken;
                        },
                    }
                },
                .Let => {
                    _ = self.advance();
                    try definitions.append(try self.variable(false));
                },
                .Identifier => {
                    try variablesTmp.append(try self.variableSignature(true, true));
                    if (!self.match(&.{.Comma})) break;
                },
                else => {
                    _ = self.advance();
                    self.report("Expected a field in union definition.", .{});
                    return error.InvalidToken;
                },
            }
        }

        _ = try self.consume(.RBrace, error.MissingBrace, "Expected enclosing brace after union definition.");

        const variables = try self.commitFromSlice(variablesTmp.items);
        const defs = try self.commitFromSlice(definitions.items);

        const start: types.OpaquePtr = @intCast(self.extra.items.len);
        self.extra.append(self.allocator(), tagged) catch return error.AllocatorFailure;
        if (tagged == 1) {
            if (tag) |t| {
                self.extra.append(self.allocator(), 1) catch return error.AllocatorFailure;
                self.extra.append(self.allocator(), t) catch return error.AllocatorFailure;
            }
            else {
                self.extra.append(self.allocator(), 0) catch return error.AllocatorFailure;
            }
        }
        self.extra.append(self.allocator(), variables.start) catch return error.AllocatorFailure;
        self.extra.append(self.allocator(), variables.end) catch return error.AllocatorFailure;
        self.extra.append(self.allocator(), defs.start) catch return error.AllocatorFailure;
        self.extra.append(self.allocator(), defs.end) catch return error.AllocatorFailure;

        const expr = try self.alloc(Expression);
        self.expressionMap.set(expr, .{
            .type = .UnionDefinition,
            .value = start,
        });

        return expr;
    }

    fn typeExpression(self: *Self) ExpressionResult {
        switch (self.tokens.items(.type)[self.advance()]) {
            .Star => {
                const res = try self.typeExpression();

                const expr = try self.alloc(Expression);
                self.expressionMap.set(expr, .{
                    .type = .PointerType,
                    .value = res,
                });
                return expr;
            },
            .LBracket => {
                _ = try self.consume(.RBracket, error.MissingBracket, "Expected enclosing bracket in slice type.");
                const res = try self.typeExpression();

                const expr = try self.alloc(Expression);
                self.expressionMap.set(expr, .{
                    .type = .SliceType,
                    .value = res,
                });
                return expr;
            },
            .Fn => {
                _ = try self.consume(.LParen, error.MissingParenthesis, "Expected a type list in function pointer type expression.");

                const paramsStart = self.scratch.items.len;
                while (!self.check(.RParen)) {
                    self.scratch.append(self.allocator(), try self.ifExpression()) catch return error.AllocatorFailure;
                    if (!self.match(&.{.Comma})) {
                        break;
                    }
                }
                _ = try self.consume(.RParen, error.MissingParenthesis, "Expected closing parenthesis ')' after parameter list.");
                const params = try self.commitScratch(paramsStart);

                _ = try self.consume(.Arrow, error.MissingArrow, "Expected arrow '->' to denote return type.");
                const returns = try self.ifExpression();

                const start: types.OpaquePtr = @intCast(self.extra.items.len);
                self.extra.append(self.allocator(), params.start) catch return error.AllocatorFailure;
                self.extra.append(self.allocator(), params.end) catch return error.AllocatorFailure;
                self.extra.append(self.allocator(), returns) catch return error.AllocatorFailure;

                const expr = try self.alloc(Expression);
                self.expressionMap.set(expr, .{
                    .type = .FunctionType,
                    .value = start,
                });
                return expr;
            },
            .Mut => {
                const res = try self.typeExpression();

                const expr = try self.alloc(Expression);
                self.expressionMap.set(expr, .{
                    .type = .MutableType,
                    .value = res,
                });
                return expr;
            },
            .Struct => return self.structDefinition(),
            .Enum => return self.enumDefinition(),
            .Union => return self.unionDefinition(),
            .Identifier => {
                const expr = try self.alloc(Expression);
                self.expressionMap.set(expr, .{
                    .type = .ValueType,
                    .value = self.previous(),
                });
                return expr;
            },

            else => {
                self.current -= 1;
                _ = try self.consume(.Identifier, error.MissingTypeSpecifier, "Expected type name.");
            }
        }

        unreachable;
    }

    //
    // Helpers
    //

    fn allocator(self: *Self) Allocator {
        return self.arena.allocator();
    }

    fn commonBinary(self: *Self, expr: types.ExpressionPtr, comptime next: anytype) ExpressionResult {
        const operator = self.tokens.items(.type)[self.previous()];
        const rhs = try next(self);

        const binaryStart: types.OpaquePtr = @intCast(self.extra.items.len);
        self.extra.append(self.allocator(), expr) catch return error.AllocatorFailure;
        self.extra.append(self.allocator(), @intFromEnum(operator)) catch return error.AllocatorFailure;
        self.extra.append(self.allocator(), rhs) catch return error.AllocatorFailure;

        const newExpr = try self.alloc(Expression);
        self.expressionMap.set(newExpr, .{
            .type = .Binary,
            .value = binaryStart,
        });

        return newExpr;
    }

    fn synchronize(self: *Self) void {
        while (!self.isAtEnd()) {
            if (self.tokens.items(.type)[self.previous()] == .Semicolon) {
                return;
            }

            switch (self.tokens.items(.type)[self.peek()]) {
                .Fn, .Let, .Pub,
                .While, .If, .Asm,
                .Continue, .Return, .Import,
                .Defer, .Extern,
                .Discard, .Break, .RBrace,
                .RBracket => {
                    return;
                },
                else => {},
            }

            _ = self.advance();
        }
    }

    fn commitFromSlice(self: *Self, items: []const types.OpaquePtr) common.CompilerError!types.Range {
        const start: types.OpaquePtr = @intCast(self.extra.items.len);
        self.extra.appendSlice(self.allocator(), items) catch return error.AllocatorFailure;
        return .{
            .start = start,
            .end = @intCast(self.extra.items.len)
        };
    }

    fn commitScratch(self: *Self, scratchStart: usize) common.CompilerError!types.Range {
        const span = try self.commitFromSlice(self.scratch.items[scratchStart..]);
        self.scratch.shrinkRetainingCapacity(@intCast(scratchStart));
        return span;
    }

    fn alloc(self: *Self, comptime T: type) common.CompilerError!types.OpaquePtr {
        if (comptime T == Expression) {
            return @intCast(self.expressionMap.addOne(self.allocator()) catch return error.AllocatorFailure);
        } else if (comptime T == Statement) {
            return @intCast(self.statementMap.addOne(self.allocator()) catch return error.AllocatorFailure);
        } else if (comptime T == VariableSignature) {
            return @intCast(try self.signaturePool.addOne(self.allocator()));
        } else {
            @compileError("Unsupported type.");
        }
    }

    fn variableSignature(self: *Self, public: bool, enforceType: bool) common.CompilerError!types.SignaturePtr {
        const name = try self.consume(.Identifier, error.MissingIdentifier, "Expected an identifier at variable signature.");
        var typename: types.ExpressionPtr = undefined;

        if (!enforceType and !self.check(.Colon)) {
            typename = 0;
        } else {
            _ = try self.consume(.Colon, error.MissingColon, "Expected a separator colon ':' after identifier.");
            typename = try self.ifExpression();
        }

        const signature = try self.alloc(VariableSignature);
        self.signaturePool.set(signature, .{
            .public = public,
            .name = name,
            .type = typename,
        });

        return signature;
    }

    fn consume(self: *Self, tokenType: lexer.TokenType, err: common.CompilerError, message: []const u8) common.CompilerError!types.TokenPtr {
        if (self.check(tokenType)) return self.advance();

        self.report("{s}\n\tExpected {s}, Received {s}", .{ message, @tagName(tokenType), @tagName(self.tokens.items(.type)[self.peek()]) });
        return err;
    }

    fn previous(self: *Self) types.TokenPtr {
        if (self.current == 0) unreachable;
        return self.current - 1;
    }

    fn peek(self: *Self) types.TokenPtr {
        return self.current;
    }

    fn isAtEnd(self: *Self) bool {
        if (self.current >= self.tokens.len) return true;
        return self.tokens.items(.type)[self.peek()] == .EOF;
    }

    fn advance(self: *Self) types.TokenPtr {
        if (!self.isAtEnd()) self.current += 1;
        return self.previous();
    }

    fn check(self: *Self, tokenType: lexer.TokenType) bool {
        if (self.isAtEnd()) return false;
        return self.tokens.items(.type)[self.peek()] == tokenType;
    }

    fn match(self: *Self, comptime args: []const lexer.TokenType) bool {
        const t = self.tokens.items(.type)[self.peek()];
        inline for (args) |arg| {
            if (t == arg) {
                _ = self.advance();
                return true;
            }
        }
        return false;
    }

    fn report(self: *Self, comptime fmt: []const u8, args: anytype) void {
        common.log.err(fmt, args);
        const token = self.tokens.get(self.previous());
        const position = token.position(self.context, self.file);
        common.log.err("\t{s} {d}:{d}", .{ self.context.getFileName(self.file), position.line, position.column});
    }

    fn getAST(self: *const Self) AST {
        return .{
            .extra = self.extra.items,
            .tokens = self.tokens,
            .statementMask = self.statementMask.items,
            .signatures = self.signaturePool.slice(),
            .expressions = self.expressionMap.slice(),
            .statements = self.statementMap.slice(),
        };
    }
};

//
// Tests
//

pub const Tests = struct {};
