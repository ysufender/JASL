const std = @import("std");
const common = @import("../core/common.zig");

pub const TokenList = std.ArrayList(Token);

pub const TokenType = union(enum) {
    LParen, RParen,
    LBrace, RBrace,
    Comma, Dot, Colon, DoubleColon, Semicolon,
    Minus, Plus, Slash, Star,
    Bang, BangEqual,
    Equal, EqualEqual,
    Greater, GreaterEqual,
    Lesser, LesserEqual,
    LeftShift, RightShift,
    Arrow,
    Pipe, Ampersant,
    Include, Namespace,
    If, Else, While,
    Return, Defer, Extern,
    Fn, Layout, Let, 
    Pub, Mut,
    And, Or,
    Identifier,
    TypeName,
    String, Integer, Float, False, True, Nullptr,
    EOF,
};

pub const Position = struct {
    const Self = @This();

    line: usize,
    column: usize,

    pub fn init(line: usize, col: usize) Self {
        return .{
            .line = line,
            .column = col
        };
    }
};

/// Token does not own the lexeme
pub const Token = struct {
    type: TokenType,
    lexeme: []const u8,
    position: Position,

    const Self = @This();

    // Token does not own the lexeme
    pub fn init(tokenType: TokenType, lexeme: []const u8, position: Position) Self {
        return .{
            .type = tokenType,
            .lexeme = lexeme,
            .position = position
        };
    }

    /// self.lexeme
    pub fn toString(self: *const Self)  void {
        std.log.info(
            "<{s}:{s}>",
            .{@tagName(self.type), self.lexeme}
        );
    }
};

pub const Scanner = struct {
    source: []const u8,
    tokens: TokenList,

    file: []const u8,

    start: usize,
    current: usize,
    line: usize,
    col: usize,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, file: []const u8, source: []const u8) common.CompilerError!Self {
        return .{
            .start = 0,
            .current = 0,
            .line = 0,
            .col = 0,
            .file = file,
            .source = source,
            .tokens = TokenList.initCapacity(allocator, 128) catch return error.InternalError,
        };
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        self.tokens.clearAndFree(allocator);
    }

    /// Releases the ownership of self.tokens
    pub fn scanAll(self: *Self, allocator: std.mem.Allocator) common.CompilerError!TokenList {
        while (!self.isAtEnd()) {
            self.start = self.current;
            try self.scanToken(allocator);
        }

        self.tokens.append(
            allocator,
            Token.init(
                TokenType.EOF,
                "EOF",
                .{
                    .line = self.line,
                    .column = 0
                }
            )
        ) catch return error.InternalError;

        const tokens = self.tokens;
        self.tokens = TokenList.empty;
        self.start = 0;
        self.current = 0;
        self.line = 0;

        return tokens;
    }

    fn scanToken(self: *Self, allocator: std.mem.Allocator) common.CompilerError!void {
        return switch (self.advance()) {
            '\n' => { },
            '(' => self.addToken(TokenType.LParen, allocator),
            ')' => self.addToken(TokenType.RParen, allocator),
            '{' => self.addToken(TokenType.LBrace, allocator),
            '}' => self.addToken(TokenType.RBrace, allocator),
            ',' => self.addToken(TokenType.Comma, allocator),
            '.' => self.addToken(TokenType.Dot, allocator),
            ':' =>
                if (self.match(':')) self.addToken(TokenType.DoubleColon, allocator)
                else self.addToken(TokenType.Colon, allocator),
            ';' => self.addToken(TokenType.Semicolon, allocator),
            '-' => 
                if (self.match('>')) self.addToken(TokenType.Arrow, allocator)
                else self.addToken(TokenType.Minus, allocator),
            '+' => self.addToken(TokenType.Plus, allocator),
            '/' => 
                if (self.match('/')) {
                    while (self.advance() != '\n') { }
                }
                else if (self.match('*')) {
                    var ident: usize = 1;

                    while (ident > 0 and !self.isAtEnd()) {
                        const ch = self.advance();

                        if (ch == '*' and self.match('/')) {
                            ident -= 1;
                        }
                        else if (ch == '/' and self.match('*')) {
                            ident += 1;
                        }
                    }

                    if (self.isAtEnd()) {
                        self.report("Unterminated multiline comment", .{});
                        return error.UnterminatedComment;
                    }
                }
                else self.addToken(TokenType.Slash, allocator),
            '*' => self.addToken(TokenType.Star, allocator),
            '!' =>
                if (self.match('=')) self.addToken(TokenType.BangEqual, allocator)
                else self.addToken(TokenType.Bang, allocator),
            '=' =>
                if (self.match('=')) self.addToken(TokenType.EqualEqual, allocator)
                else self.addToken(TokenType.Equal, allocator),
            '>' =>
                if (self.match('=')) self.addToken(TokenType.GreaterEqual, allocator)
                else if (self.match('>')) self.addToken(TokenType.RightShift, allocator)
                else self.addToken(TokenType.Greater, allocator),
            '<' =>
                if (self.match('=')) self.addToken(TokenType.LesserEqual, allocator)
                else if (self.match('<')) self.addToken(TokenType.LeftShift, allocator)
                else self.addToken(TokenType.Lesser, allocator),
            '|' => self.addToken(TokenType.Pipe, allocator),
            '&' => self.addToken(TokenType.Ampersant, allocator),
            '"' => {
                while (self.peek() != '"' and !self.isAtEnd()) {
                    _ = self.advance();
                }

                if (self.isAtEnd()) {
                    self.report("Unterminated string literal", .{});
                    return error.UnterminatedStringLiteral;
                }

                _ = self.advance();
                try self.addToken(TokenType.String, allocator);
            },
            // TODO: character literals
            else => |ch|
                if (std.ascii.isDigit(ch)) {
                    // TODO: allow underscore
                    while (std.ascii.isDigit(self.peek())) {
                        _ = self.advance();
                    }

                    if (self.peek() == '.' and std.ascii.isDigit(self.peekn(1))) {
                        _ = self.advance();

                        while (std.ascii.isDigit(self.peek())) {
                            _ = self.advance();
                        }

                        return self.addToken(TokenType.Float, allocator);
                    }

                    return self.addToken(TokenType.Integer, allocator);
                }
                else if (std.ascii.isAlphabetic(ch)){
                    self.current -= 1;
                    while (std.ascii.isAlphanumeric(self.peek())) {
                        _ = self.advance();
                    }

                    const str = self.source[self.start..self.current];

                    if (!std.ascii.isUpper(str[0])) {
                        return self.addToken(
                            getType(str),
                            allocator
                        );
                    }

                    while (self.peek() == '*') { _ = self.advance(); }
                    try self.addToken(TokenType.TypeName, allocator);
                }
                else {
                    self.report("Unexpected character {c}", .{ch});
                    return error.InvalidToken;
                }
        };
    }

    fn match(self: *Self, expected: u8) bool {
        if (self.isAtEnd()) return false;
        if (self.source[self.current] != expected) return false;

        _ = self.advance();
        return true;
    }

    fn peek(self: *Self) u8 {
        if (self.isAtEnd()) return 0;
        return self.source[self.current];
    }

    fn peekn(self: *Self, n: usize) u8 {
        if (self.current + n >= self.source.len) return 0;
        return self.source[self.current + n];
    }

    fn advance(self: *Self) u8 {
        self.current += 1;
        switch (self.source[self.current-1]) {
            '\n' => {
                self.line += 1;
                self.col = 0;
                self.start = self.current;
                return '\n';
            },
            ' ', '\t', '\r' => {
                self.start = self.current;
            },
            else => |ch| { return ch; }
        }

        return self.advance();
    }

    fn addToken(self: *Self, tokenType: TokenType, allocator: std.mem.Allocator) common.CompilerError!void {
        const str = self.source[self.start..self.current];
        self.tokens.append(allocator, .init(tokenType, str, .init(self.line, self.col)))
            catch return error.InvalidToken;
    }

    fn isAtEnd(self: *Self) bool {
        return self.current >= self.source.len;
    }

    fn getType(str: []const u8) TokenType {
        return
            if (std.mem.eql(u8, str, "and")) TokenType.And
            else if (std.mem.eql(u8, str, "or")) TokenType.Or
            else if (std.mem.eql(u8, str, "if")) TokenType.If
            else if (std.mem.eql(u8, str, "else")) TokenType.Else
            else if (std.mem.eql(u8, str, "while")) TokenType.While
            else if (std.mem.eql(u8, str, "fn")) TokenType.Fn
            else if (std.mem.eql(u8, str, "return")) TokenType.Return
            else if (std.mem.eql(u8, str, "defer")) TokenType.Defer
            else if (std.mem.eql(u8, str, "extern")) TokenType.Extern
            else if (std.mem.eql(u8, str, "let")) TokenType.Let
            else if (std.mem.eql(u8, str, "include")) TokenType.Include
            else if (std.mem.eql(u8, str, "namespace")) TokenType.Namespace
            else if (std.mem.eql(u8, str, "false")) TokenType.False
            else if (std.mem.eql(u8, str, "true")) TokenType.True
            else if (std.mem.eql(u8, str, "nullptr")) TokenType.Nullptr
            else if (std.mem.eql(u8, str, "layout")) TokenType.Layout
            else if (std.mem.eql(u8, str, "pub")) TokenType.Pub
            else if (std.mem.eql(u8, str, "mut")) TokenType.Mut
            else TokenType.Identifier;
    }

    fn report(self: *Self, comptime fmt: []const u8, args: anytype) void {
        std.log.err(fmt, args);
        std.log.err("\t{s} {d}:{d}\n", .{self.file, self.line, self.col});
    }
};
