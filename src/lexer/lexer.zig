const std = @import("std");
const common = @import("../core/common.zig");

pub const TokenList = std.ArrayList(Token);

pub const TokenType = enum {
    LParen, RParen,
    LBrace, RBrace,
    LBracket, RBracket,
    Comma, Dot, Colon, DoubleColon, Semicolon,
    Xor, Tilde, Minus, Plus, Slash, Star,
    Bang, BangEqual,
    Equal, EqualEqual,
    Greater, GreaterEqual,
    Lesser, LesserEqual,
    LeftShift, RightShift,
    Arrow,
    Pipe, Ampersand,
    Include, Namespace,
    If, Else, While,
    Return, Defer, Extern,
    Break, Continue,
    Fn, Layout, Let, 
    Asm,
    Pub, Mut,
    And, Or,
    Identifier,
    TypeName,
    String, Integer, Float, False, True, Nullptr,
    Discard,
    EOF,
};

/// Position does not own the file
pub const Position = struct {
    const Self = @This();


    file: []const u8,
    line: usize,
    column: usize,

    pub fn init(file: []const u8, line: usize, col: usize) Self {
        return .{
            .file = file,
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

    pub const eof: Self = .{
        .type = .EOF,
        .lexeme = "",
        .position = .{
            .file = "",
            .line = 0,
            .column = 0
        }
    };

    // Token does not own the lexeme
    pub fn init(tokenType: TokenType, lexeme: []const u8, position: Position) Self {
        return .{
            .type = tokenType,
            .lexeme = lexeme,
            .position = position
        };
    }

    pub fn toString(self: *const Self, allocator: std.mem.Allocator) []const u8 {
        const length =  @tagName(self.type).len + self.lexeme.len + 4;
        const buffer = allocator.alloc(u8, length) catch return "";
        return std.fmt.bufPrint(buffer, "<{s}: {s}>", .{@tagName(self.type), self.lexeme}) catch unreachable;
    }
};

/// Scanner does not own neither the file, nor the source
pub const Scanner = struct {
    source: []const u8,
    tokens: TokenList,

    file: []const u8,

    start: usize,
    current: usize,
    line: usize,
    col: usize,

    const Self = @This();

    //
    // Public API
    //

    /// Scanner does not own neither the file, nor the source
    pub fn init(file: []const u8, source: []const u8) common.CompilerError!Self {
        return .{
            .start = 0,
            .current = 0,
            .line = 1,
            .col = 0,
            .file = file,
            .source = source,
            .tokens = TokenList.empty,
        };
    }

    /// Releases the ownership of self.tokens
    pub fn scanAll(self: *Self, allocator: std.mem.Allocator) common.CompilerError![]Token {
        while (!self.isAtEnd()) {
            self.start = self.current;
            try self.scanToken(allocator);
        }

        self.tokens.append(
            allocator,
            Token.init(
                .EOF,
                "EOF",
                .{
                    .file = self.file,
                    .line = self.line,
                    .column = 0
                }
            )
        ) catch return error.InternalError;

        self.start = 0;
        self.current = 0;
        self.line = 1;
        self.col = 1;

        return self.tokens.toOwnedSlice(allocator) catch error.AllocatorFailure;
    }

    //
    // Private Implementation
    //

    fn scanToken(self: *Self, allocator: std.mem.Allocator) common.CompilerError!void {
        return switch (self.advance()) {
            '\n' => { },
            '(' => self.addToken(.LParen, allocator),
            ')' => self.addToken(.RParen, allocator),
            '{' => self.addToken(.LBrace, allocator),
            '}' => self.addToken(.RBrace, allocator),
            '[' => self.addToken(.LBracket, allocator),
            ']' => self.addToken(.RBracket, allocator),
            ',' => self.addToken(.Comma, allocator),
            '~' => self.addToken(.Tilde, allocator),
            '^' => self.addToken(.Xor, allocator),
            '.' => 
                if (std.ascii.isDigit(self.peek())) {
                    self.report("Dot (.) prefixed numeric literals are not allowed.", .{});
                    return error.DotPrefixedNumericLiteral;
                }
                else self.addToken(.Dot, allocator),
            ':' =>
                if (self.match(':')) self.addToken(.DoubleColon, allocator)
                else self.addToken(.Colon, allocator),
            ';' => self.addToken(.Semicolon, allocator),
            '-' => 
                if (self.match('>')) self.addToken(.Arrow, allocator)
                else self.addToken(.Minus, allocator),
            '+' => self.addToken(.Plus, allocator),
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
                else self.addToken(.Slash, allocator),
            '*' => self.addToken(.Star, allocator),
            '!' =>
                if (self.match('=')) self.addToken(.BangEqual, allocator)
                else self.addToken(.Bang, allocator),
            '=' =>
                if (self.match('=')) self.addToken(.EqualEqual, allocator)
                else self.addToken(.Equal, allocator),
            '>' =>
                if (self.match('=')) self.addToken(.GreaterEqual, allocator)
                else if (self.match('>')) self.addToken(.RightShift, allocator)
                else self.addToken(.Greater, allocator),
            '<' =>
                if (self.match('=')) self.addToken(.LesserEqual, allocator)
                else if (self.match('<')) self.addToken(.LeftShift, allocator)
                else self.addToken(.Lesser, allocator),
            '|' => self.addToken(.Pipe, allocator),
            '&' => self.addToken(.Ampersand, allocator),
            '"' => {
                while (!self.check('"') and !self.isAtEnd()) {
                    _ = self.advance();
                }

                if (self.isAtEnd()) {
                    self.report("Unterminated string literal", .{});
                    return error.UnterminatedStringLiteral;
                }

                _ = self.advance();
                try self.addToken(.String, allocator);
            },
            // TODO: character literals
            else => |ch|
                if (std.ascii.isDigit(ch)) {
                    // TODO: allow underscore
                    while (std.ascii.isDigit(self.peek())) {
                        _ = self.advance();
                    }

                    if (self.check('.') and std.ascii.isDigit(self.peekn(1))) {
                        _ = self.advance();

                        while (std.ascii.isDigit(self.peek())) {
                            _ = self.advance();
                        }

                        return self.addToken(.Float, allocator);
                    }
                    else if (self.check('.')) {
                        _ = self.advance();
                        self.report("Trailing dots (.) after numeric literals are not allowed.", .{});
                        return error.DotPostfixedNumericLiteral;
                    }

                    return self.addToken(.Integer, allocator);
                }
                else if (std.ascii.isAlphabetic(ch) or ch == '_'){
                    while (std.ascii.isAlphanumeric(self.peek()) or self.check('_')) {
                        _ = self.advance();
                    }

                    const str = self.source[self.start..self.current];

                    if (getType(str) != .TypeName) {
                        return self.addToken(
                            getType(str),
                            allocator
                        );
                    }

                    try self.addToken(.TypeName, allocator);
                }
                else {
                    self.report("Unexpected character {c}", .{ch});
                    return error.UnexpectedCharacter;
                }
        };
    }

    //
    // Helpers
    //

    fn check(self: *Self, expected: u8) bool {
        if (self.isAtEnd()) return false;
        return self.source[self.current] == expected;
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
        self.col += 1;
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
        self.tokens.append(allocator, .init(tokenType, str, .init(self.file, self.line, self.col)))
            catch return error.InvalidToken;
    }

    fn isAtEnd(self: *Self) bool {
        return self.current >= self.source.len;
    }

    fn getType(str: []const u8) TokenType {
        return
            if (std.mem.eql(u8, str, "and")) .And
            else if (std.mem.eql(u8, str, "or")) .Or
            else if (std.mem.eql(u8, str, "if")) .If
            else if (std.mem.eql(u8, str, "else")) .Else
            else if (std.mem.eql(u8, str, "while")) .While
            else if (std.mem.eql(u8, str, "fn")) .Fn
            else if (std.mem.eql(u8, str, "return")) .Return
            else if (std.mem.eql(u8, str, "defer")) .Defer
            else if (std.mem.eql(u8, str, "extern")) .Extern
            else if (std.mem.eql(u8, str, "let")) .Let
            else if (std.mem.eql(u8, str, "include")) .Include
            else if (std.mem.eql(u8, str, "namespace")) .Namespace
            else if (std.mem.eql(u8, str, "false")) .False
            else if (std.mem.eql(u8, str, "true")) .True
            else if (std.mem.eql(u8, str, "nullptr")) .Nullptr
            else if (std.mem.eql(u8, str, "layout")) .Layout
            else if (std.mem.eql(u8, str, "pub")) .Pub
            else if (std.mem.eql(u8, str, "mut")) .Mut
            else if (std.mem.eql(u8, str, "asm")) .Asm
            else if (std.mem.eql(u8, str, "break")) .Break
            else if (std.mem.eql(u8, str, "continue")) .Continue
            else if (std.mem.eql(u8, str, "bool")) .TypeName
            else if (std.mem.eql(u8, str, "u32")) .TypeName
            else if (std.mem.eql(u8, str, "i32")) .TypeName
            else if (std.mem.eql(u8, str, "u8")) .TypeName
            else if (std.mem.eql(u8, str, "i8")) .TypeName
            else if (std.mem.eql(u8, str, "float")) .TypeName
            else if (std.mem.eql(u8, str, "_")) .Discard
            else if (std.mem.eql(u8, str, "type")) .TypeName
            else if (std.mem.eql(u8, str, "any")) .TypeName
            else .Identifier;
    }

    fn report(self: *Self, comptime fmt: []const u8, args: anytype) void {
        common.log.err("[LEXER ERROR] ", .{});
        common.log.err(fmt, args);
        common.log.err("\t{s} {d}:{d}\n", .{self.file, self.line, self.col});
    }
};

//
// Tests
//
pub const Tests = struct {
};
