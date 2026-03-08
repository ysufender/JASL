const std = @import("std");
const common = @import("../core/common.zig");
const lexer = @import("../lexer/lexer.zig");

const TokenType = lexer.TokenType;
const Allocator = std.mem.Allocator;

const ExpressionResult = common.CompilerError!*Expression;

const StatementResult = common.CompilerError!*Statement;
const StatementList = std.ArrayList(*Statement);
const VariableSignatureList = std.ArrayList(VariableSignature);
const TypeList = std.ArrayList(*Expression);
const IdentifierList = std.ArrayList(lexer.Token);
const ExpressionList = std.ArrayList(*Expression);

pub const Expression = union(enum) {
    Binary: struct {
        lhs: *Expression,
        operator: TokenType,
        rhs: *Expression,
    },
    Grouping: *Expression,
    Literal: lexer.Token,
    Identifier: lexer.Token,
    Unary: struct {
        operator: TokenType,
        rhs: *Expression,
    },
    LayoutDefinition: VariableSignatureList,
    Call: struct {
        function: *Expression,
        arguments: ExpressionList, 
    },
    Conditional: struct {
        condition: *Expression,
        then: *Expression,
        otherwise: *Expression,
    },
    Type: struct {
        mutable: bool,
        type: union(enum) {
            Pointer: *Expression,
            Slice: *Expression,
            Function: struct {
                parameters: TypeList,
                returns: TypeList,
            },
            Value: lexer.Token,
        },
    },
    Scoping: struct {
        namespace: *Expression,
        member: lexer.Token,
    },
    ExpressionList: ExpressionList,
    Dot: struct {
        lhs: *Expression,
        rhs: lexer.Token,
    },
    Indexing: struct {
        lhs: *Expression,
        index: *Expression,
    },
};

pub const Statement = union(enum) {
    Block: StatementList,
    InlineAssembly: []const u8,
    FunctionDefinition: struct {
        public: bool,
        name: lexer.Token,
        params: VariableSignatureList,
        returnType: TypeList,
        body: *Statement,
    },
    Return: *Expression,
    Conditional: struct {
        condition: *Expression,
        body: *Statement,
        otherwise: ?*Statement,
    },
    While: struct {
        condition: *Expression,
        body: *Statement,
    },
    Break,
    Continue,
    VariableDefinition: struct {
        signatures: VariableSignatureList,
        initializer: *Expression,
    },
    Discard: *Expression,
    Namespace: *Expression,
    Include: lexer.Token,
};

pub const VariableSignature = struct {
    public: bool,
    name: lexer.Token,
    type: ?*Expression,
};

pub const Parser = struct {
    const Self = @This();

    tokens: []const lexer.Token,
    current: usize,

    //
    // Public API
    //

    pub fn init(tokens: []const lexer.Token) Parser {
        return .{
            .tokens = tokens,
            .current = 0,
        };
    }

    pub fn parse(self: *Self, allocator: Allocator) common.CompilerError!StatementList {
        var list = StatementList.empty;

        while (!self.isAtEnd()) {
            list.append(allocator, try self.statement(allocator)) catch return error.AllocatorFailure;
        }

        return list;
    }

    //
    // Private Implementation
    //

    //
    // Statements
    //

    fn statement(self: *Self, allocator: Allocator) StatementResult {
        return switch (self.advance().type) {
            .LBrace => self.block(allocator),
            .Asm => self.inlineAssembly(allocator),
            .If => self.conditional(allocator),
            .While => self.whileStatement(allocator),
            .Return => self.returnStatement(allocator),
            .Break => self.breakStatement(allocator),
            .Continue => self.continueStatement(allocator),
            .Pub => switch (self.advance().type) {
                .Fn => self.function(allocator, true),
                .Let => self.variable(allocator, true),
                else => {
                    self.report("Expected a function or a variable definition after 'pub' specifier.", .{});
                    return error.InvalidToken;
                },
            },
            .Fn => self.function(allocator, false),
            .Let => self.variable(allocator, false),
            .Discard => self.discard(allocator),
            .Namespace => self.namespace(allocator), 
            .Include => self.include(allocator), 
            else => unreachable,
        };
    }

    fn block(self: *Self, allocator: Allocator) StatementResult {
        var statements = StatementList.empty;

        while (!self.isAtEnd() and !self.check(.RBrace)) {
            statements.append(allocator, try self.statement(allocator)) catch return error.AllocatorFailure;
        }

        _ = try self.consume(.RBrace, error.MissingBrace, "Missing enclosing brace '}' after block.");

        const result = allocator.create(Statement) catch return error.AllocatorFailure;
        result.* = .{
            .Block = statements
        };
        return result;
    }

    fn inlineAssembly(self: *Self, allocator: Allocator) StatementResult {
        _ = try self.consume(.LBrace, error.MissingBrace, "Expected block after 'asm' statement.");
        var str = std.ArrayList(u8).empty;

        while (!self.isAtEnd() and !self.check(.RBrace)) {
            str.appendSlice(allocator, self.advance().lexeme) catch return error.AllocatorFailure;
        }

        _ = try self.consume(.RBrace, error.MissingBrace, "Missing enclosing brace '}' after 'asm' statement.");

        const result = allocator.create(Statement) catch return error.AllocatorFailure;
        result.* = .{
            .InlineAssembly = str.items
        };
        return result;
    }

    fn returnStatement(self: *Self, allocator: Allocator) StatementResult {
        const expr = try self.expression(allocator);

        _ = try self.consume(.Semicolon, error.MissingSemicolon, "Expected semicolon after statement.");

        const result = allocator.create(Statement) catch return error.AllocatorFailure;
        result.* = .{
            .Return = expr
        };
        return result;
    }

    fn conditional(self: *Self, allocator: Allocator) StatementResult {
        const condition = try self.expression(allocator);
        const body = try self.statement(allocator);
        var otherwise: ?*Statement = null;

        if (self.match(&.{.Else})) {
            otherwise.? = try self.statement(allocator);
        }

        const result = allocator.create(Statement) catch return error.AllocatorFailure;
        result.* = .{
            .Conditional = .{
                .condition = condition,
                .body = body,
                .otherwise = otherwise
            }
        };
        return result;
    }

    fn whileStatement(self: *Self, allocator: Allocator) StatementResult {
        const condition = try self.expression(allocator);
        const body = try self.statement(allocator);

        const result = allocator.create(Statement) catch return error.AllocatorFailure;
        result.* = .{
            .While = .{
                .condition = condition,
                .body = body
            }
        };
        return result;
    }
    
    fn breakStatement(self: *Self, allocator: Allocator) StatementResult {
        _ = try self.consume(.Semicolon, error.MissingSemicolon, "Expected semicolon after statement.");

        const result = allocator.create(Statement) catch return error.AllocatorFailure;
        result.* = .{
            .Break = {},
        };
        return result;
    }

    fn continueStatement(self: *Self, allocator: Allocator) StatementResult {
        _ = try self.consume(.Semicolon, error.MissingSemicolon, "Expected semicolon after statement.");

        const result = allocator.create(Statement) catch return error.AllocatorFailure;
        result.* = .{
            .Continue = {},
        };
        return result;
    }

    fn function(self: *Self, allocator: Allocator, public: bool) StatementResult {
        const name = try self.consume(.Identifier, error.MissingIdentifier, "Expected a function name.");
        _ = try self.consume(.LParen, error.MissingParenthesis, "Expected parenthesis '(' after function name.");

        var vars = VariableSignatureList.empty;
        while (!self.isAtEnd() and !self.check(.RParen)) {
            vars.append(allocator, try self.variableSignature(allocator, false, true)) catch return error.AllocatorFailure;

            if (!self.match(&.{.Comma}))
                break;
        }
        _ = try self.consume(.RParen, error.MissingParenthesis, "Expected closing parenthesis ')' after parameter list.");
        _ = try self.consume(.Arrow, error.MissingArrow, "Expected arrow '->' to denote return type.");

        var returns = TypeList.empty;
        while (!self.isAtEnd()) {
            returns.append(allocator, try self.expression(allocator)) catch return error.AllocatorFailure;

            if (self.check(.LBrace))
                break;

            _ = try self.consume(.Comma, error.MissingComma, "Expected comma in return type list.");
        }
        _ = try self.consume(.LBrace, error.MissingBrace, "Expected function body after return type list.");
        self.current -= 1;

        const body = try self.statement(allocator);

        const result = allocator.create(Statement) catch return error.AllocatorFailure;
        result.* = .{
            .FunctionDefinition = .{
                .public = public,
                .name = name,
                .params = vars,
                .returnType = returns,
                .body = body,
            },
        };
        return result;
    }

    fn variable(self: *Self, allocator: Allocator, public: bool) StatementResult {
        var signatures = VariableSignatureList.empty;

        while (!self.isAtEnd() and !self.check(.Equal)) {
            signatures.append(allocator, try self.variableSignature(allocator, public, false)) catch return error.AllocatorFailure;

            if (!self.match(&.{.Comma}))
                break;
        }
        _ = try self.consume(.Equal, error.MissingAssignment, "Expected assignment in variable definition.");

        const expr = try self.expression(allocator);

        _ = try self.consume(.Semicolon, error.MissingSemicolon, "Expected semicolon after statement.");

        const result = allocator.create(Statement) catch return error.AllocatorFailure;
        result.* = .{
            .VariableDefinition = .{
                .signatures = signatures,
                .initializer = expr,
            },
        };
        return result;
    }

    fn discard(self: *Self, allocator: Allocator) StatementResult {
        _ = try self.consume(.Equal, error.MissingAssignment, "Expected an assignment after discard.");

        const expr = try self.expression(allocator);

        _ = try self.consume(.Semicolon, error.MissingSemicolon, "Expected semicolon after statement.");
        
        const result = allocator.create(Statement) catch return error.AllocatorFailure;
        result.* = .{
            .Discard = expr,
        };
        return result;
    }

    fn namespace(self: *Self, allocator: Allocator) StatementResult {
        const expr = try self.scoping(allocator);

        _ = try self.consume(.Semicolon, error.MissingSemicolon, "Expected semicolon after statement.");

        const result = allocator.create(Statement) catch return error.AllocatorFailure;
        result.* = .{
            .Namespace = expr,
        };
        return result;
    }

    fn include(self: *Self, allocator: Allocator) StatementResult {
        const file = try self.consume(.String, error.InvalidToken, "Expected file path in include statement.");
        _ = try self.consume(.Semicolon, error.MissingSemicolon, "Expected semicolon after statement.");

        const result = allocator.create(Statement) catch return error.AllocatorFailure;
        result.* = .{
            .Include = file,
        };
        return result;
    }

    //
    // Expressions
    //

    fn expression(self: *Self, allocator: Allocator) ExpressionResult {
        return self.assignment(allocator);
    }

    fn assignment(self: *Self, allocator: Allocator) ExpressionResult {
        var expr = try self.ifExpression(allocator);

        while (self.match(&.{.Equal})) {
            const operator = self.previous().type;
            const rhs = try self.assignment(allocator);

            const newExpr = allocator.create(Expression) catch return error.AllocatorFailure;
            newExpr.* = .{
                .Binary = .{
                    .lhs = expr,
                    .operator = operator,
                    .rhs = rhs,
                },
            };

            expr = newExpr;
        }

        return expr;
    }

    fn ifExpression(self: *Self, allocator: Allocator) ExpressionResult {
        if (!self.match(&.{.If})) {
            return self.logicalOr(allocator);
        }

        const condition = try self.expression(allocator);
        const then = try self.expression(allocator);

        _ = try self.consume(.Else, error.MissingBranch, "Expected an 'else' branch in conditional expression.");

        const otherwise = try self.expression(allocator);

        const expr = allocator.create(Expression) catch return error.AllocatorFailure;
        expr.* = .{
            .Conditional = .{
                .condition = condition,
                .then = then,
                .otherwise = otherwise,
            },
        };

        return expr;
    }

    fn logicalOr(self: *Self, allocator: Allocator) ExpressionResult {
        var expr = try self.logicalAnd(allocator);

        while (self.match(&.{.Or})) {
            const operator = self.previous().type;
            const rhs = try self.logicalAnd(allocator);

            const newExpr = allocator.create(Expression) catch return error.AllocatorFailure;
            newExpr.* = .{
                .Binary = .{
                    .lhs = expr,
                    .operator = operator,
                    .rhs = rhs,
                },
            };

            expr = newExpr;
        }

        return expr;
    }

    fn logicalAnd(self: *Self, allocator: Allocator) ExpressionResult {
        var expr = try self.equality(allocator);

        while (self.match(&.{.And})) {
            const operator = self.previous().type;
            const rhs = try self.equality(allocator);

            const newExpr = allocator.create(Expression) catch return error.AllocatorFailure;
            newExpr.* = .{
                .Binary = .{
                    .lhs = expr,
                    .operator = operator,
                    .rhs = rhs,
                },
            };

            expr = newExpr;
        }

        return expr;
    }

    fn equality(self: *Self, allocator: Allocator) ExpressionResult {
        var expr = try self.bitwiseOr(allocator);

        while (self.match(&.{.EqualEqual, .BangEqual})) {
            const operator = self.previous().type;
            const rhs = try self.bitwiseOr(allocator);

            const newExpr = allocator.create(Expression) catch return error.AllocatorFailure;
            newExpr.* = .{
                .Binary = .{
                    .lhs = expr,
                    .operator = operator,
                    .rhs = rhs,
                },
            };

            expr = newExpr;
        }

        return expr;
    }

    fn bitwiseOr(self: *Self, allocator: Allocator) ExpressionResult {
        var expr = try self.bitwiseXor(allocator);

        while (self.match(&.{.Pipe})) {
            const operator = self.previous().type;
            const rhs = try self.bitwiseXor(allocator);

            const newExpr = allocator.create(Expression) catch return error.AllocatorFailure;
            newExpr.* = .{
                .Binary = .{
                    .lhs = expr,
                    .operator = operator,
                    .rhs = rhs,
                },
            };

            expr = newExpr;
        }

        return expr;
    }

    fn bitwiseXor(self: *Self, allocator: Allocator) ExpressionResult {
        var expr = try self.bitwiseAnd(allocator);

        while (self.match(&.{.Xor})) {
            const operator = self.previous().type;
            const rhs = try self.bitwiseAnd(allocator);

            const newExpr = allocator.create(Expression) catch return error.AllocatorFailure;
            newExpr.* = .{
                .Binary = .{
                    .lhs = expr,
                    .operator = operator,
                    .rhs = rhs,
                },
            };

            expr = newExpr;
        }

        return expr;
    }

    fn bitwiseAnd(self: *Self, allocator: Allocator) ExpressionResult {
        var expr = try self.comparison(allocator);

        while (self.match(&.{.Ampersand})) {
            const operator = self.previous().type;
            const rhs = try self.comparison(allocator);

            const newExpr = allocator.create(Expression) catch return error.AllocatorFailure;
            newExpr.* = .{
                .Binary = .{
                    .lhs = expr,
                    .operator = operator,
                    .rhs = rhs,
                },
            };

            expr = newExpr;
        }

        return expr;
    }
    
    fn comparison(self: *Self, allocator: Allocator) ExpressionResult {
        var expr = try self.shift(allocator);

        while (self.match(&.{.Lesser, .LesserEqual, .Greater, .GreaterEqual})) {
            const operator = self.previous().type;
            const rhs = try self.shift(allocator);

            const newExpr = allocator.create(Expression) catch return error.AllocatorFailure;
            newExpr.* = .{
                .Binary = .{
                    .lhs = expr,
                    .operator = operator,
                    .rhs = rhs,
                },
            };

            expr = newExpr;
        }

        return expr;
    }

    fn shift(self: *Self, allocator: Allocator) ExpressionResult {
        var expr = try self.term(allocator);

        while (self.match(&.{.RightShift, .LeftShift})) {
            const operator = self.previous().type;
            const rhs = try self.term(allocator);

            const newExpr = allocator.create(Expression) catch return error.AllocatorFailure;
            newExpr.* = .{
                .Binary = .{
                    .lhs = expr,
                    .operator = operator,
                    .rhs = rhs,
                },
            };

            expr = newExpr;
        }

        return expr;
    }

    fn term(self: *Self, allocator: Allocator) ExpressionResult {
        var expr = try self.factor(allocator);

        while (self.match(&.{.Plus, .Minus})) {
            const operator = self.previous().type;
            const rhs = try self.factor(allocator);

            const newExpr = allocator.create(Expression) catch return error.AllocatorFailure;
            newExpr.* = .{
                .Binary = .{
                    .lhs = expr,
                    .operator = operator,
                    .rhs = rhs,
                },
            };

            expr = newExpr;
        }

        return expr;
    }

    fn factor(self: *Self, allocator: Allocator) ExpressionResult {
        var expr = try self.unary(allocator);

        while (self.match(&.{.Slash, .Star})) {
            const operator = self.previous().type;
            const rhs = try self.unary(allocator);

            const newExpr = allocator.create(Expression) catch return error.AllocatorFailure;
            newExpr.* = .{
                .Binary = .{
                    .lhs = expr,
                    .operator = operator,
                    .rhs = rhs,
                },
            };

            expr = newExpr;
        }

        return expr;
    }

    fn unary(self: *Self, allocator: Allocator) ExpressionResult {
        while (self.match(&.{.Bang, .Minus, .Plus, .Tilde})) {
            const operator = self.previous().type;
            const rhs = try self.unary(allocator);

            const expr = allocator.create(Expression) catch return error.AllocatorFailure;
            expr.* = .{
                .Unary = .{
                    .operator = operator,
                    .rhs = rhs,
                },
            };
            return expr;
        }

        return self.postfix(allocator);
    }

    fn postfix(self: *Self, allocator: Allocator) ExpressionResult {
        var expr = try self.primary(allocator);

        while (true) {
            if (self.match(&.{.LParen})) {
                var arguments = ExpressionList.empty;

                while (!self.isAtEnd() and !self.check(.RParen)) {
                    arguments.append(allocator, try self.expression(allocator)) catch return error.AllocatorFailure;

                    if (!self.match(&.{.Comma})) {
                        break;
                    }
                }
                _ = try self.consume(.RParen, error.MissingParenthesis, "Expected closing parenthesis ')' in function call.");

                const newExpr = allocator.create(Expression) catch return error.AllocatorFailure;
                newExpr.* = .{
                    .Call = .{
                        .function = expr,
                        .arguments = arguments,
                    },
                };
                
                expr = newExpr;
            }
            else if (self.match(&.{.Dot})) {
                if (!self.match(&.{.Identifier, .Ampersand, .Star})) {
                    self.report("Expected a function name or a member name in dot expression.", .{});
                    return error.MissingIdentifier;
                }

                const member = self.previous();

                const newExpr = allocator.create(Expression) catch return error.AllocatorFailure;
                newExpr.* = .{
                    .Dot = .{
                        .lhs = expr,
                        .rhs = member,
                    },
                };
                expr = newExpr;
            }
            else if (self.match(&.{.LBracket})) {
                const index = try self.expression(allocator);

                _ = try self.consume(.RBracket, error.MissingBracket, "Expected closing bracket ']'.");

                const newExpr = allocator.create(Expression) catch return error.AllocatorFailure;
                newExpr.* = .{
                    .Indexing = .{
                        .lhs = expr,
                        .index = index,
                    },
                };
                expr = newExpr;
            }
            else if (self.match(&.{.DoubleColon})) {
                switch (expr.*) {
                    .Identifier, .Scoping, .Dot => { },
                    else => {
                        self.report("Expected a identifier name in scoping expression.", .{});
                        return error.MissingIdentifier;
                    }
                }
                const member = try self.consume(.Identifier, error.MissingIdentifier, "Expected member name in scope resolution.");

                const newExpr = allocator.create(Expression) catch return error.AllocatorFailure;
                newExpr.* = .{
                    .Scoping = .{
                        .namespace = expr,
                        .member = member,
                    },
                };

                expr = newExpr;
            }
            else {
                break;
            }
        }

        return expr;
    }

    fn scoping(self: *Self, allocator: Allocator) ExpressionResult {
        var expr = try self.primary(allocator);

        while (self.match(&.{.DoubleColon})) {
            switch (expr.*) {
                .Identifier, .Scoping => { },
                else => {
                    self.report("Expected a namespace name in scoping expression.", .{});
                    return error.MissingIdentifier;
                }
            }
            const member = try self.consume(.Identifier, error.MissingIdentifier, "Expected member name in scope resolution.");

            const newExpr = allocator.create(Expression) catch return error.AllocatorFailure;
            newExpr.* = .{
                .Scoping = .{
                    .namespace = expr,
                    .member = member,
                },
            };

            expr = newExpr;
        }

        return expr;
    }

    fn primary(self: *Self, allocator: Allocator) ExpressionResult {
        switch (self.peek().type) {
            .False,
            .True,
            .Nullptr,
            .Integer,
            .Float,
            .String => {
                const expr = allocator.create(Expression) catch return error.AllocatorFailure;
                expr.* = .{
                    .Literal = self.advance(), 
                };
                return expr;
            },
            .TypeName => return self.typeExpression(allocator, false),
            .Mut => {
                _ = self.advance();
                return self.typeExpression(allocator, true);
            },
            .LParen => {
                _ = self.advance();
                const expr = try self.expression(allocator);
                _ = try self.consume(.RParen, error.MissingParenthesis, "Expected an enclosing ')' after expression.");
                const newExpr = allocator.create(Expression) catch return error.AllocatorFailure;
                newExpr.* = .{
                    .Grouping = expr
                };
                return newExpr;
            },
            .Identifier => {
                const expr = allocator.create(Expression) catch return error.AllocatorFailure;
                expr.* = .{
                    .Identifier = self.advance(),
                };
                return expr;
            },
            else => {
                self.report("Expected a primary expression, got '{s}' instead.", .{self.advance().lexeme});
                return error.InvalidToken;
            }
        }
    }

    fn typeExpression(self: *Self, allocator: Allocator, mutable: bool) ExpressionResult {
        if (!self.check(.Identifier) and !self.check(.TypeName)) {
            self.report("Expected type name.", .{});
            return error.MissingTypeSpecifier;
        }

        const expr = allocator.create(Expression) catch return error.AllocatorFailure;

        expr.* = .{
            .Type = .{
                .mutable = mutable,
                .type = .{
                    .Value = self.advance(),
                },
            },
        };

        return self.parseTypeSuffixes(allocator, expr);
    }

    fn parseTypeSuffixes(self: *Self, allocator: Allocator, expr: *Expression) ExpressionResult {
        var base = expr;

        while (true) {
            if (self.match(&.{.Star})) {
                const newExpr = allocator.create(Expression) catch return error.AllocatorFailure;
                newExpr.* = .{
                    .Type = .{
                        .mutable = base.Type.mutable,
                        .type = .{
                            .Pointer = base,
                        },
                    },
                };

                base = newExpr;
            }
            else if (self.match(&.{.LBracket})) {
                _ = try self.consume(.RBracket, error.MissingBracket, "Expected enclosing bracket ']'.");

                const newExpr = allocator.create(Expression) catch return error.AllocatorFailure;
                newExpr.* = .{
                    .Type = .{
                        .mutable = base.Type.mutable,
                        .type = .{
                            .Slice = base,
                        },
                    },
                };

                base = newExpr;
            }
            else {
                break;
            }
        }

        return base;
    }

    //
    // Helpers
    //

    fn variableSignature(self: *Self, allocator: Allocator, public: bool, enforceType: bool) common.CompilerError!VariableSignature {
        const name = try self.consume(.Identifier, error.MissingIdentifier, "Expected an identifier at variable signature.");

        if (!enforceType and !self.check(.Colon)) {
            return .{
                .public = public,
                .name = name,
                .type = null,
            };
        }

        _ = try self.consume(.Colon, error.MissingColon, "Expected a separator colon ':' after identifier.");
        
        const typename = try self.expression(allocator);
        
        return .{
            .public = public,
            .name = name,
            .type = typename,
        };
    }

    fn consume(self: *Self, tokenType: TokenType, err: common.CompilerError, message: []const u8) common.CompilerError!lexer.Token {
        if (self.check(tokenType)) return self.advance();

        self.report("{s}\n\tExpected {s}, Received {s}", .{message, @tagName(tokenType), @tagName(self.peek().type)});
        return err;
    }

    fn previous(self: *Self) lexer.Token {
        if (self.current == 0) return lexer.Token.eof;
        return self.tokens[self.current - 1];
    }

    fn peek(self: *Self) lexer.Token {
        return self.tokens[self.current];
    }

    fn isAtEnd(self: *Self) bool {
        return self.peek().type == .EOF;
    }

    fn advance(self: *Self) lexer.Token {
        if (!self.isAtEnd()) self.current += 1;
        return self.previous();
    }

    fn check(self: *Self, tokenType: TokenType) bool {
        if (self.isAtEnd()) return false;
        return self.peek().type == tokenType;
    }

    fn match(self: *Self, args: []const TokenType) bool {
        for (args) |arg| {
            if (self.check(arg)) {
                _ = self.advance();
                return true;
            }
        }

        return false;
    }

    fn report(self: *Self, comptime fmt: []const u8, args: anytype) void {
        common.log.err("[PARSER ERROR]", .{});
        common.log.err(fmt, args);
        const token = self.previous();
        common.log.err("\t{s} {d}:{d}\n", .{token.position.file, token.position.line, token.position.column});
    }
};

//
// Tests
//

pub const Tests = struct {
};
