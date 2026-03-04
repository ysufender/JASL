const std = @import("std");
const util = @import("../core/util.zig");

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
    Fn, Return, Defer, Extern, Let,
    String, Number, False, True, Nullptr,
    EOF,
};

pub const Position = struct {
    line: u32,
    column: u32,
};

/// Token does not own the lexeme
pub const Token = struct {
    type: TokenType,
    lexeme: []const u8,
    position: Position,

    const Self = @This();

    pub fn new(tokenType: TokenType, lexeme: []const u8, position: Position) Self {
        return .{
            .type = tokenType,
            .lexeme = lexeme,
            .position = position
        };
    }

    pub fn toString(self: *Self, allocator: std.mem.Allocator) void {
        util.println(
            allocator,
            "<{s}: {s}>",
            .{@tagName(self.type), self.lexeme}
        );
    }
};
