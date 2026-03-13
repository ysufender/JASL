const std = @import("std");
const common = @import("../core/common.zig");
const lexer = @import("../lexer/lexer.zig");
const arraylist = @import("../util/arraylist.zig");

const TokenType = lexer.TokenType;
const Allocator = std.mem.Allocator;
const ExpressionResult = common.CompilerError!ExpressionPtr;

pub const StatementResult = common.CompilerError!StatementPtr;

const NodeList = Range;
const NodePtr = u32;

const ExpressionPtr = u32;
const StatementPtr = u32;
const TokenPtr = u32;

pub const VariableSignatureMap = arraylist.MultiArrayList(VariableSignature);
pub const ExpressionMap = arraylist.MultiArrayList(Expression);
pub const StatementMap = arraylist.MultiArrayList(Statement);

pub const Range = struct {
    start: u32,
    end: u32,
};

pub const Expression = struct {
    type: enum {
        Binary,
        Grouping,
        Literal,
        Indexing,
        Identifier,
        Unary,
        LayoutDefinition,
        Call,
        Conditional,
        Mutable,
        Pointer,
        Slice,
        Function,
        Value,
        Scoping,
        ExpressionList,
        Dot,
    },

    value: union {
        DirectPtr: NodePtr,
        List: Range,
    },
};

// pub const Expression = union(enum) {
//     Binary: NodePtr,
//     Grouping: ExpressionPtr,
//     Literal: TokenPtr,
//     Identifier: TokenPtr,
//     Unary: NodePtr,
//     LayoutDefinition: NodePtr,
//     Call: NodePtr,
//     Conditional: NodePtr,
//     Mutable: ExpressionPtr,
//     Pointer: ExpressionPtr,
//     Slice: ExpressionPtr,
//     Function: NodePtr,
//     Value: NodePtr,
//     Scoping: NodePtr,
//     ExpressionList: NodeList,
//     Dot: NodePtr,
//     Indexing: NodePtr,
// };

pub const Statement = struct {
    type: enum {
        Block,
        InlineAssembly,
        FunctionDefinition,
        Return,
        Conditional,
        While,
        Break,
        Continue,
        VariableDefinition,
        Discard,
        Namespace,
        Include,
    },

    value: NodePtr,
};

// pub const Statement = union(enum) {
//     Block: NodePtr,
//     InlineAssembly: TokenPtr,
//     FunctionDefinition: NodePtr,
//     Return: ExpressionPtr,
//     Conditional: NodePtr,
//     While: NodePtr,
//     Break,
//     Continue,
//     VariableDefinition: NodePtr,
//     Discard: ExpressionPtr,
//     Namespace: ExpressionPtr,
//     Include: TokenPtr,
// };

pub const VariableSignature = struct {
    public: bool,
    name: u32,
    type: u32,
};

pub const Parser = struct {
    const Self = @This();

    tokens: lexer.TokenList,
    current: u32,

    arena: std.heap.ArenaAllocator,

    expressionMap: ExpressionMap,
    statementMap: StatementMap,
    signaturePool: VariableSignatureMap,

    extra: std.ArrayList(u32),
    scratch: std.ArrayList(u32),

    file: u32,

    pub fn init(base: Allocator, tokens: lexer.TokenList) common.CompilerError!Parser {
        var arena = std.heap.ArenaAllocator.init(base);
        var self = Self{
            .signaturePool = try VariableSignatureMap.init(arena.allocator(), tokens.len / 2),
            .expressionMap = try ExpressionMap.init(arena.allocator(), tokens.len / 2),
            .statementMap = try StatementMap.init(arena.allocator(), tokens.len / 4),
            // .expressionMap = ExpressionMap.empty,
            // .statementMap = StatementMap.empty,
            .file = tokens.items(.start)[0],
            .tokens = tokens,
            .current = 1,
            .arena = arena,
            .extra = .empty,
            .scratch = .empty,
        };
        
        // self.expressionMap.ensureTotalCapacity(self.allocator(), tokens.len / 2) catch return error.AllocatorFailure;
        // self.statementMap.ensureTotalCapacity(self.allocator(), tokens.len / 4) catch return error.AllocatorFailure;
        self.extra.ensureTotalCapacity(self.allocator(), tokens.len) catch return error.AllocatorFailure;
        self.scratch.ensureTotalCapacity(self.allocator(), 128) catch return error.AllocatorFailure;

        return self;
    }

    pub fn parse(self: *Self) common.CompilerError!void {
        var errCount: u32 = 0;
        var lastErr: common.CompilerError = undefined;

        while (!self.isAtEnd()) {
            _ = self.statement() catch |err| {
                errCount += 1;
                lastErr = err;
                common.log.err("Error: {d} <{s}>\n", .{ @intFromError(err), @errorName(err) });
                self.synchronize();
                if (errCount == common.CompilerSettings.settings.maxErr) {
                    common.log.err("Too many errors, aborting compilation.", .{});
                    return err;
                }
            };
        }

        if (errCount > 1) {
            lastErr = error.MultipleErrors;
        }
        else if (errCount > 0) {
            return lastErr;
        }

        return;
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
                .Fn => self.function(true),
                .Let => self.variable(true),
                else => {
                    self.report("Expected a function or a variable definition after 'pub' specifier.", .{});
                    return error.InvalidToken;
                },
            },
            .Fn => self.function(false),
            .Let => self.variable(false),
            .Discard => self.discard(),
            .Namespace => self.namespace(),
            .Include => self.include(),
            .Semicolon => self.statement(),
            else => {
                self.report("Expected statement.", .{});
                return error.MissingStatement;
            },
        };
    }

    fn block(self: *Self) StatementResult {
        const scratchStart = self.scratch.items.len;
        while (!self.check(.RBrace)) {
            self.scratch.append(self.allocator(), try self.statement()) catch return error.AllocatorFailure;
        }

        _ = try self.consume(.RBrace, error.MissingBrace, "Missing enclosing brace '}' after block.");
        const stmts = try self.commitList(scratchStart);

        const start: u32 = @intCast(self.extra.items.len);
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
        std.log.info("{s}", .{self.tokens.get(asmly).lexeme(self.file)});

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
        const body = try self.statement();

        var otherwise: ?u32 = null;
        if (self.match(&.{.Else})) {
            otherwise.? = try self.statement();
        }

        const start: u32 = @intCast(self.extra.items.len);
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
        const body = try self.statement();

        const start: u32 = @intCast(self.extra.items.len);
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

    fn function(self: *Self, public: bool) StatementResult {
        const name = try self.consume(.Identifier, error.MissingIdentifier, "Expected a function name.");
        _ = try self.consume(.LParen, error.MissingParenthesis, "Expected parenthesis '(' after function name.");

        const paramsStart = self.scratch.items.len;
        while (!self.check(.RParen)) {
            self.scratch.append(self.allocator(), try self.variableSignature(false, true)) catch return error.AllocatorFailure;
            if (!self.match(&.{.Comma})) break;
        }
        _ = try self.consume(.RParen, error.MissingParenthesis, "Expected closing parenthesis ')' after parameter list.");
        const params = try self.commitList(paramsStart);

        _ = try self.consume(.Arrow, error.MissingArrow, "Expected arrow '->' to denote return type.");

        const returnsStart = self.scratch.items.len;
        while (!self.isAtEnd()) {
            self.scratch.append(self.allocator(), try self.primary()) catch return error.AllocatorFailure;
            if (self.check(.LBrace)) break;
            _ = try self.consume(.Comma, error.MissingComma, "Expected comma in return type list.");
        }
        const returns = try self.commitList(returnsStart);

        _ = try self.consume(.LBrace, error.MissingBrace, "Expected function body after return type list.");
        self.current -= 1;

        const body = try self.statement();

        const start: u32 = @intCast(self.extra.items.len);
        self.extra.append(self.allocator(), @intFromBool(public)) catch return error.AllocatorFailure;
        self.extra.append(self.allocator(), name) catch return error.AllocatorFailure;
        self.extra.append(self.allocator(), params.start) catch return error.AllocatorFailure;
        self.extra.append(self.allocator(), params.end) catch return error.AllocatorFailure;
        self.extra.append(self.allocator(), returns.start) catch return error.AllocatorFailure;
        self.extra.append(self.allocator(), returns.end) catch return error.AllocatorFailure;
        self.extra.append(self.allocator(), body) catch return error.AllocatorFailure;

        const result = try self.alloc(Statement);
        
        self.statementMap.set(result, .{
            .type = .FunctionDefinition,
            .value = start,
        });

        return result;
    }

    fn variable(self: *Self, public: bool) StatementResult {
        const sigsStart = self.scratch.items.len;
        while (!self.check(.Equal)) {
            self.scratch.append(self.allocator(), try self.variableSignature(public, false)) catch return error.AllocatorFailure;
            if (!self.match(&.{.Comma})) break;
        }
        const signatures = try self.commitList(sigsStart);

        _ = try self.consume(.Equal, error.MissingAssignment, "Expected assignment in variable definition.");
        const expr = try self.expression();
        _ = try self.consume(.Semicolon, error.MissingSemicolon, "Expected semicolon after statement.");

        const start: u32 = @intCast(self.extra.items.len);
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

    fn namespace(self: *Self) StatementResult {
        const expr = try self.scoping();
        _ = try self.consume(.Semicolon, error.MissingSemicolon, "Expected semicolon after statement.");

        const result = try self.alloc(Statement);
        self.statementMap.set(result, .{
            .type = .Namespace,
            .value = expr
        });

        return result;
    }

    fn include(self: *Self) StatementResult {
        const file = try self.consume(.String, error.InvalidToken, "Expected file path in include statement.");
        _ = try self.consume(.Semicolon, error.MissingSemicolon, "Expected semicolon after statement.");

        const result = try self.alloc(Statement);
        self.statementMap.set(result, .{
            .type = .Include,
            .value = file
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
            expr = try self.commonBinary(expr, Self.assignment);
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

        const start: u32 = @intCast(self.extra.items.len);
        self.extra.append(self.allocator(), condition) catch return error.AllocatorFailure;
        self.extra.append(self.allocator(), then) catch return error.AllocatorFailure;
        self.extra.append(self.allocator(), otherwise) catch return error.AllocatorFailure;

        const expr = try self.alloc(Expression);
        self.expressionMap.set(expr, .{
            .type = .Conditional,
            .value = .{ .DirectPtr = start },
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
            const expr = try self.alloc(Expression);

            const start: u32 = @intCast(self.extra.items.len);
            self.extra.append(self.allocator(), @intFromEnum(operator)) catch return error.AllocatorFailure;
            self.extra.append(self.allocator(), rhs) catch return error.AllocatorFailure;

            self.expressionMap.set(expr, .{
                .type = .Unary,
                .value = .{ .DirectPtr = start },
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
                const args = try self.commitList(argsStart);

                const start: u32 = @intCast(self.extra.items.len);
                self.extra.append(self.allocator(), expr) catch return error.AllocatorFailure;
                self.extra.append(self.allocator(), args.start) catch return error.AllocatorFailure;
                self.extra.append(self.allocator(), args.end) catch return error.AllocatorFailure;

                const newExpr = try self.alloc(Expression);
                self.expressionMap.set(newExpr, .{
                    .type = .Call,
                    .value = .{ .DirectPtr = start },
                });
                expr = newExpr;
            } else if (self.match(&.{.Dot})) {
                if (!self.match(&.{.Identifier, .Ampersand, .Star})) {
                    _ = self.advance();
                    self.report("Expected a function name or a member name in dot expression.", .{});
                    return error.MissingIdentifier;
                }

                const member = self.previous();
                const newExpr = try self.alloc(Expression);

                const start: u32 = @intCast(self.extra.items.len);
                self.extra.append(self.allocator(), expr) catch return error.AllocatorFailure;
                self.extra.append(self.allocator(), member) catch return error.AllocatorFailure;

                self.expressionMap.set(newExpr, .{
                    .type = .Dot,
                    .value = .{ .DirectPtr = start },
                });
                expr = newExpr;
            } else if (self.match(&.{.LBracket})) {
                const index = try self.expression();
                _ = try self.consume(.RBracket, error.MissingBracket, "Expected closing bracket ']'.");

                const start: u32 = @intCast(self.extra.items.len);
                self.extra.append(self.allocator(), expr) catch return error.AllocatorFailure;
                self.extra.append(self.allocator(), index) catch return error.AllocatorFailure;

                const newExpr = try self.alloc(Expression);
                self.expressionMap.set(newExpr, .{
                    .type = .Indexing,
                    .value = .{ .DirectPtr = start },
                });
                expr = newExpr;
            } else if (self.match(&.{.DoubleColon})) {
                switch (self.expressionMap.get(expr).type) {
                    .Identifier, .Scoping, .Dot => {},
                    else => {
                        self.report("Expected a identifier name in scoping expression.", .{});
                        return error.MissingIdentifier;
                    },
                }

                const member = try self.consume(.Identifier, error.MissingIdentifier, "Expected member name in scope resolution.");
                const newExpr = try self.alloc(Expression);

                const start: u32 = @intCast(self.extra.items.len);
                self.extra.append(self.allocator(), expr) catch return error.AllocatorFailure;
                self.extra.append(self.allocator(), member) catch return error.AllocatorFailure;

                self.expressionMap.set(newExpr, .{
                    .type = .Scoping,
                    .value = .{ .DirectPtr = start },
                });
                expr = newExpr;
            } else {
                break;
            }
        }

        return expr;
    }

    fn scoping(self: *Self) ExpressionResult {
        var expr = try self.primary();

        while (self.match(&.{.DoubleColon})) {
            switch (self.expressionMap.get(expr).type) {
                .Identifier, .Scoping => {},
                else => {
                    self.report("Expected a namespace name in scoping expression.", .{});
                    return error.MissingIdentifier;
                },
            }

            const member = try self.consume(.Identifier, error.MissingIdentifier, "Expected member name in scope resolution.");
            const newExpr = try self.alloc(Expression);

            const start: u32 = @intCast(self.extra.items.len);
            self.extra.append(self.allocator(), expr) catch return error.AllocatorFailure;
            self.extra.append(self.allocator(), member) catch return error.AllocatorFailure;

            self.expressionMap.set(newExpr, .{
                .type = .Scoping,
                .value = .{ .DirectPtr = start },
            });
            expr = newExpr;
        }

        return expr;
    }

    fn primary(self: *Self) ExpressionResult {
        switch (self.tokens.items(.type)[self.peek()]) {
            .False, .True, .Nullptr, .Integer, .Float, .String => {
                const expr = try self.alloc(Expression);
                self.expressionMap.set(expr, .{
                    .type = .Literal,
                    .value = .{ .DirectPtr = self.advance() },
                });
                return expr;
            },
            .Fn, .Mut, .Layout, .Star, .LBracket => return self.typeExpression(),
            .LParen => {
                _ = self.advance();
                const inner = try self.expression();
                _ = try self.consume(.RParen, error.MissingParenthesis, "Expected an enclosing ')' after expression.");

                const expr = try self.alloc(Expression);
                self.expressionMap.set(expr, .{
                    .type = .Grouping,
                    .value = .{ .DirectPtr = inner },
                });
                return expr;
            },
            .LBrace => {
                _ = self.advance();
                const exprsStart = self.scratch.items.len;

                while (!self.check(.RBrace)) {
                    self.scratch.append(self.allocator(), try self.expression()) catch return error.AllocatorFailure;
                    if (!self.match(&.{.Comma})) {
                        break;
                    }
                }

                _ = try self.consume(.RBrace, error.MissingBrace, "Expected enclosing brace '}' in expression list.");
                const expressions = try self.commitList(exprsStart);

                const expr = try self.alloc(Expression);
                self.expressionMap.set(expr, .{
                    .type = .ExpressionList,
                    .value = .{ .List = expressions },
                });
                return expr;
            },
            .Identifier => {
                const expr = try self.alloc(Expression);
                self.expressionMap.set(expr, .{
                    .type = .Identifier,
                    .value = .{ .DirectPtr = self.advance() },
                });
                return expr;
            },
            else => {
                self.report("Expected a primary expression, got '{s}' instead.", .{self.tokens.get(self.advance()).lexeme(self.file)});
                return error.InvalidToken;
            },
        }
    }

    fn typeExpression(self: *Self) ExpressionResult {
        const expr = try self.alloc(Expression);

        switch (self.tokens.items(.type)[self.advance()]) {
            .Star => {
                const res = try self.expression();
                self.expressionMap.set(expr, .{
                    .type = .Pointer,
                    .value = .{ .DirectPtr = res },
                });
            },
            .LBracket => {
                _ = try self.consume(.RBracket, error.MissingBracket, "Expected enclosing bracket in slice type.");
                const res = try self.expression();
                self.expressionMap.set(expr, .{
                    .type = .Slice,
                    .value = .{ .DirectPtr = res },
                });
            },
            .Fn => {
                _ = try self.consume(.LParen, error.MissingParenthesis, "Expected a type list in function pointer type expression.");
                
                const paramsStart = self.scratch.items.len;
                while (!self.check(.RParen)) {
                    self.scratch.append(self.allocator(), try self.expression()) catch return error.AllocatorFailure;
                    if (!self.match(&.{.Comma})) {
                        break;
                    }
                }
                _ = try self.consume(.RParen, error.MissingParenthesis, "Expected closing parenthesis ')' after parameter list.");
                const params = try self.commitList(paramsStart);

                _ = try self.consume(.Arrow, error.MissingArrow, "Expected arrow '->' to denote return type.");
                const returnsStart = self.scratch.items.len;
                if (self.match(&.{.LParen})) {
                    while (!self.check(.RParen)) {
                        self.scratch.append(self.allocator(), try self.expression()) catch return error.AllocatorFailure;
                        if (!self.match(&.{.Comma})) {
                            break;
                        }
                    }
                    _ = try self.consume(.RParen, error.MissingParenthesis, "Expected closing parenthesis ')' after parameter list.");
                }
                else {
                    self.scratch.append(self.allocator(), try self.expression()) catch return error.AllocatorFailure;
                }
                const returns = try self.commitList(returnsStart);

                const start: u32 = @intCast(self.extra.items.len);
                self.extra.append(self.allocator(), params.start) catch return error.AllocatorFailure;
                self.extra.append(self.allocator(), params.end) catch return error.AllocatorFailure;
                self.extra.append(self.allocator(), returns.start) catch return error.AllocatorFailure;
                self.extra.append(self.allocator(), returns.end) catch return error.AllocatorFailure;

                self.expressionMap.set(expr, .{
                    .type = .Function,
                    .value = .{ .DirectPtr = start },
                });
            },
            .Mut => {
                const res = try self.expression();

                self.expressionMap.set(expr, .{
                    .type = .Mutable,
                    .value = .{ .DirectPtr = res },
                });
            },
            .Layout => {
                _ = try self.consume(.LBrace, error.MissingBrace, "Expected layout body.");

                var variablesTmp = std.ArrayList(u32).initCapacity(self.allocator(), 5) catch return error.AllocatorFailure;
                var functionsTmp = std.ArrayList(u32).initCapacity(self.allocator(), 5) catch return error.AllocatorFailure;

                while (!self.check(.RBrace)) {
                    switch (self.tokens.items(.type)[self.peek()]) {
                        .Pub => {
                            _ = self.advance();
                            switch (self.tokens.items(.type)[self.peek()]) {
                                .Fn => {
                                    _ = self.advance();
                                    functionsTmp.append(self.allocator(), try self.function(true)) catch return error.AllocatorFailure;
                                },
                                .Identifier => {
                                    variablesTmp.append(self.allocator(), try self.variableSignature(true, true)) catch return error.AllocatorFailure;
                                    if (!self.match(&.{.Comma})) break;
                                },
                                else => {
                                    _ = self.advance();
                                    self.report("Expected a function or a field definition after 'pub' specifier.", .{});
                                    return error.InvalidToken;
                                },
                            }
                        },
                        .Fn => {
                            _ = self.advance();
                            functionsTmp.append(self.allocator(), try self.function(false)) catch return error.AllocatorFailure;
                        },
                        .Identifier => {
                            variablesTmp.append(self.allocator(), try self.variableSignature(false, true)) catch return error.AllocatorFailure;
                            if (!self.match(&.{.Comma})) break;
                        },
                        else => {
                            _ = self.advance();
                            self.report("Expected a function or a field definition in layout definition.", .{});
                            return error.InvalidToken;
                        },
                    }
                }

                _ = try self.consume(.RBrace, error.MissingBrace, "Expected enclosing brace after layout definition.");

                const variables = try self.commitFromSlice(variablesTmp.items);
                const functions = try self.commitFromSlice(functionsTmp.items);

                const start: u32 = @intCast(self.extra.items.len);
                self.extra.append(self.allocator(), variables.start) catch return error.AllocatorFailure;
                self.extra.append(self.allocator(), variables.end) catch return error.AllocatorFailure;
                self.extra.append(self.allocator(), functions.start) catch return error.AllocatorFailure;
                self.extra.append(self.allocator(), functions.end) catch return error.AllocatorFailure;

                self.expressionMap.set(expr, .{
                    .type = .LayoutDefinition,
                    .value = .{ .DirectPtr = start },
                });
            },
            .Identifier => {
                const start: u32 = @intCast(self.extra.items.len);
                self.extra.append(self.allocator(), @intFromBool(true)) catch return error.AllocatorFailure;
                self.extra.append(self.allocator(), self.previous()) catch return error.AllocatorFailure;

                self.expressionMap.set(expr, .{
                    .type = .Value,
                    .value = .{ .DirectPtr = start },
                });
            },

            else => {
                self.current -= 1;
                _ = try self.consume(.Identifier, error.MissingTypeSpecifier, "Expected type name.");
            }
        }

        return expr;
    }

    //
    // Helpers
    //

    fn allocator(self: *Self) Allocator {
        return self.arena.allocator();
    }

    fn commonBinary(self: *Self, expr: u32, comptime next: anytype) ExpressionResult {
        const operator = self.tokens.items(.type)[self.previous()];
        const rhs = try next(self);
        const newExpr = try self.alloc(Expression);

        const binaryStart: u32 = @intCast(self.extra.items.len);
        self.extra.append(self.allocator(), expr) catch return error.AllocatorFailure;
        self.extra.append(self.allocator(), @intFromEnum(operator)) catch return error.AllocatorFailure;
        self.extra.append(self.allocator(), rhs) catch return error.AllocatorFailure;

        self.expressionMap.set(newExpr, .{
            .type = .Binary,
            .value = .{ .DirectPtr = binaryStart },
        });

        return newExpr;
    }

    fn synchronize(self: *Self) void {
        while (!self.isAtEnd()) {
            if (self.tokens.items(.type)[self.previous()] == .Semicolon) {
                return;
            }

            switch (self.tokens.items(.type)[self.peek()]) {
                .Fn, .Let, .Pub, .While, .If, .Asm, .Continue, .Return, .Include, .Namespace, .Defer, .Extern, .Discard, .Break => {
                    return;
                },
                else => {},
            }

            _ = self.advance();
        }
    }

    fn commitFromSlice(self: *Self, items: []const u32) common.CompilerError!Range {
        const start: u32 = @intCast(self.extra.items.len);
        self.extra.appendSlice(self.allocator(), items) catch return error.AllocatorFailure;
        return Range{ .start = start, .end = @intCast(self.extra.items.len) };
    }

    fn commitList(self: *Self, scratchStart: usize) common.CompilerError!Range {
        const span = try self.commitFromSlice(self.scratch.items[scratchStart..]);
        self.scratch.shrinkRetainingCapacity(scratchStart);
        return span;
    }

    fn alloc(self: *Self, comptime T: type) common.CompilerError!u32 {
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

    fn variableSignature(self: *Self, public: bool, enforceType: bool) common.CompilerError!u32 {
        const name = try self.consume(.Identifier, error.MissingIdentifier, "Expected an identifier at variable signature.");
        var typename: u32 = undefined;

        if (!enforceType and !self.check(.Colon)) {
            const start: u32 = @intCast(self.extra.items.len);
            self.extra.append(self.allocator(), @intFromBool(false)) catch return error.AllocatorFailure;

            typename = try self.alloc(Expression);
            self.expressionMap.set(typename, .{
                .type = .Value,
                .value = .{ .DirectPtr = start },
            });
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

    fn consume(self: *Self, tokenType: TokenType, err: common.CompilerError, message: []const u8) common.CompilerError!TokenPtr {
        if (self.check(tokenType)) return self.advance();

        self.report("{s}\n\tExpected {s}, Received {s}", .{ message, @tagName(tokenType), @tagName(self.tokens.items(.type)[self.peek()]) });
        return err;
    }

    fn previous(self: *Self) TokenPtr {
        if (self.current == 0) unreachable;
        return self.current - 1;
    }

    fn peek(self: *Self) TokenPtr {
        return self.current;
    }

    fn isAtEnd(self: *Self) bool {
        if (self.current >= self.tokens.len) return true;
        return self.tokens.items(.type)[self.peek()] == .EOF;
    }

    fn advance(self: *Self) TokenPtr {
        if (!self.isAtEnd()) self.current += 1;
        return self.previous();
    }

    fn check(self: *Self, tokenType: TokenType) bool {
        if (self.isAtEnd()) return false;
        return self.tokens.items(.type)[self.peek()] == tokenType;
    }

    fn match(self: *Self, comptime args: []const TokenType) bool {
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
        const position = token.position(self.file);
        common.log.err("\t{s} {d}:{d}", .{ common.CompilerContext.filenameMap[self.file], position.line, position.column});
    }
};

pub const StreamingParser = struct {
    inner: Parser,
};

//
// Tests
//

pub const Tests = struct {};
