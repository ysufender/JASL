const std = @import("std");
const util = @import("../core/util.zig");
const common = @import("../core/common.zig");

pub const TokenList = std.ArrayList(Token);

pub const TokenType = enum {
    LParen, RParen,
    LBrace, RBrace,
    Comma, Dot, Colon, DoubleColon, Semicolon,
    Minus, Plus, Slash, Star,
    Bang, BangEqual,
    Equal, EqualEqual,
    Greater, GreaterEqual,
    Less, LesserEqual,
    Identifier, TypeName,
    Ampersant, And, Or, Pipe,
    LeftShift, RightShift,
    If, Else, While,
    Fn, Return, Defer, Extern, Let, Include, Module,
    String, Number, False, True, Nullptr,
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
    pub fn toString(self: *const Self, allocator: std.mem.Allocator) void {
        util.print(
            allocator,
            "<{s}: {s}>",
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
            '\n', '\r' => {
                self.line += 1;
                self.col = 0;
            },
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
            '-' => self.addToken(TokenType.Minus, allocator),
            '+' => self.addToken(TokenType.Plus, allocator),
            '/' => self.addToken(TokenType.Slash, allocator),
            '*' => self.addToken(TokenType.Star, allocator),
            '!' =>
                if (self.match('=')) self.addToken(TokenType.BangEqual, allocator)
                else self.addToken(TokenType.Bang, allocator),
            '=' =>
                if (self.match('=')) self.addToken(TokenType.EqualEqual, allocator)
                else self.addToken(TokenType.Equal, allocator),
            else => |ch| {
                self.report(allocator, "Unexpected character '{c}'", .{ch});
                return error.InvalidToken;
            }
        };
    }

    fn match(self: *Self, expected: u8) bool {
        if (self.isAtEnd()) return false;
        if (self.source[self.current] != expected) return false;

        self.current += 1;
        return true;
    }

    fn advance(self: *Self) u8 {
        self.current += 1;
        return self.source[self.current-1];
    }

    fn addToken(self: *Self, tokenType: TokenType, allocator: std.mem.Allocator) common.CompilerError!void {
        const str = self.source[self.start..self.current];
        self.tokens.append(allocator, .init(tokenType, str, .init(self.line, self.col)))
            catch return error.InvalidToken;
    }

    fn isAtEnd(self: *Self) bool {
        return self.current >= self.source.len;
    }

    fn report(self: *Self, allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) void {
        util.println(allocator, fmt, args);
        util.println(allocator, "\t{s} {d}:{d}\n", .{self.file, self.line, self.col});
    }
};
