const std = @import("std");
const common = @import("../core/common.zig");
const collections = @import("../util/collections.zig");
const defines = @import("../core/defines.zig");

pub const TokenList = collections.MultiArrayList(Token);

pub const TokenType = enum(u8) {
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
    Import,
    If, Else, While,
    Switch,
    Return, Defer, Extern,
    Break, Continue,
    Fn, Struct, Let, Enum, Union,
    Asm,
    Pub, Mut,
    And, Or, Mark,
    Identifier,
    String, Integer, Float, False, True, EnumLiteral,
    Discard,
    Cast,
    EOF,
};

pub const Position = struct {
    line: defines.Offset,
    column: defines.Offset,
};

pub const Token = struct {
    type: TokenType,
    start: defines.Offset,
    end: defines.Offset,

    pub const eof = Token{
        .type = .EOF,
        .start = 0,
        .end = 0,
    };

    pub fn toString(self: *const Token, gpa: std.mem.Allocator, file: defines.FilePtr) []const u8 {
        const string = self.lexeme(file);
        const length =  @tagName(self.type).len + lex.len + 4;
        const buffer = gpa.alloc(u8, length) catch return "";
        return std.fmt.bufPrint(buffer, "<{s}: {s}>", .{@tagName(self.type), string}) catch unreachable;
    }

    pub fn lexeme(self: *const Token, context: *common.CompilerContext, file: defines.FilePtr) []const u8 {
        return context.getFile(file)[self.start..self.end];
    }

    pub fn position(self: *const Token, context: *common.CompilerContext, file: defines.FilePtr) Position {
        const source = context.getFile(file)[0..self.start];
        var line: defines.Offset = 1;
        var col: defines.Offset = 0;

        for (source) |ch| {
            if (ch == '\n') {
                line += 1;
                col = 0;
            }

            col += 1;
        }

        return .{
            .line = line,
            .column = col,
        };
    }
};

const Lexer = @This();

const keywords = std.StaticStringMap(TokenType).initComptime(&.{
    .{ "and", .And },
    .{ "or", .Or },
    .{ "if", .If },
    .{ "else", .Else },
    .{ "while", .While },
    .{ "fn", .Fn },
    .{ "return", .Return },
    .{ "defer", .Defer },
    .{ "extern", .Extern },
    .{ "let", .Let },
    .{ "import", .Import },
    .{ "false", .False },
    .{ "true", .True },
    .{ "struct", .Struct },
    .{ "enum", .Enum },
    .{ "union", .Union},
    .{ "pub", .Pub },
    .{ "mut", .Mut },
    .{ "asm", .Asm },
    .{ "break", .Break },
    .{ "continue", .Continue },
    .{ "switch", .Switch },
    .{ "as", .Cast },
    .{ "mark", .Mark },
    .{ "_", .Discard },
});

tokens: TokenList,
file: defines.FilePtr,
source: []const u8,

start: defines.Offset,
current: defines.Offset,
end: defines.Offset,

arena: std.heap.ArenaAllocator,
context: *common.CompilerContext,

//
// Public API
//

pub fn init(base: std.mem.Allocator, context: *common.CompilerContext, file: []const u8) common.CompilerError!Lexer {
    const fileHandle = try context.openRead(file);

    const src = context.getFile(fileHandle);
    const len: u32 = @intCast(src.len);

    var arena = std.heap.ArenaAllocator.init(base);
    var tokens = try TokenList.init(arena.allocator(), len + 2);

    tokens.appendAssumeCapacity(.{
        .type = .Semicolon,
        .start = fileHandle,
        .end = fileHandle,
    });
    
    var self = Lexer{
        .start = 0,
        .current = 0,
        .end = len,
        .file = fileHandle,
        .source = src,
        .arena = arena,
        .tokens = tokens,
        .context = context,
    };

    self.skipWhitespace();
    return self;
}

pub fn lex(self: *Lexer) common.CompilerError!defines.TokenListPtr {
    while (!self.isAtEnd()) {
        try self.scanToken();
        self.skipWhitespace();
    }

    self.tokens.append(
        self.allocator(),
        .{
            .type = .EOF,
            .start = self.start,
            .end = self.current,
        }
    ) catch return error.InternalError;

    self.start = 0;
    self.current = 0;

    return self.context.registerTokens(self.tokens.toOwnedSlice());
}

pub fn lexToken(self: *Lexer) common.CompilerError!Token {
    if (self.isAtEnd()) {
        return .{
            .type = .EOF,
            .start = self.end,
            .end = self.end,
        };
    }
    else {
        try self.scanToken();
        return self.tokens[self.tokens.len - 1];
    }
}

//
// Private Implementation
//

fn scanToken(self: *Lexer) common.CompilerError!void {
    self.start = self.current;

    return blk: switch (self.advance()) {
        '(' => self.addToken(.LParen),
        ')' => self.addToken(.RParen),
        '{' => self.addToken(.LBrace),
        '}' => self.addToken(.RBrace),
        '[' => self.addToken(.LBracket),
        ']' => self.addToken(.RBracket),
        ',' => self.addToken(.Comma),
        '~' => self.addToken(.Tilde),
        '^' => self.addToken(.Xor),
        '.' => 
            if (std.ascii.isDigit(self.peek())) {
                self.report("Dot (.) prefixed numeric literals are not allowed.", .{});
                break :blk error.DotPrefixedNumericLiteral;
            }
            else self.addToken(.Dot),
        ':' =>
            if (self.match(':')) self.addToken(.DoubleColon)
            else self.addToken(.Colon),
        ';' => self.addToken(.Semicolon),
        '-' => 
            if (self.match('>')) self.addToken(.Arrow)
            else self.addToken(.Minus),
        '+' => self.addToken(.Plus),
        '/' => 
            if (self.match('/')) {
                const index =
                    if (std.mem.indexOfScalarPos(u8, self.source, self.current, '\n'))
                        |idx| idx
                    else
                        self.end;

                self.current = @intCast(index);
            }
            else if (self.match('*')) {
                var ident: u32 = 1;

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
                    break :blk error.UnterminatedComment;
                }
            }
            else self.addToken(.Slash),
        '*' => self.addToken(.Star),
        '!' =>
            if (self.match('=')) self.addToken(.BangEqual)
            else self.addToken(.Bang),
        '=' =>
            if (self.match('=')) self.addToken(.EqualEqual)
            else self.addToken(.Equal),
        '>' =>
            if (self.match('=')) self.addToken(.GreaterEqual)
            else if (self.match('>')) self.addToken(.RightShift)
            else self.addToken(.Greater),
        '<' =>
            if (self.match('=')) self.addToken(.LesserEqual)
            else if (self.match('<')) self.addToken(.LeftShift)
            else self.addToken(.Lesser),
        '|' => self.addToken(.Pipe),
        '&' => self.addToken(.Ampersand),
        '\'' => {
            const ch = self.advance();

            if (ch == '\'') {
                self.report("Empty character literals are not allowed.", .{});
                break :blk error.EmptyCharLiteral;
            }

            _ = try self.consume('\'', "Expected closing single quote (')");
            self.start += 1;
            try self.addToken(.Integer);
        },
        '"' => {
            const index =
                if (std.mem.indexOfScalarPos(u8, self.source, self.current, '"'))
                    |idx| idx
                else
                    self.end;

            self.current = @intCast(index);

            if (self.isAtEnd()) {
                self.report("Unterminated string literal", .{});
                break :blk error.UnterminatedStringLiteral;
            }

            self.start += 1;
            try self.addToken(.String);
        },
        '@' => {
            const ch = self.advance();
            if (std.ascii.isAlphabetic(ch) or ch == '_'){
                const alpha = comptime "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz_";
                const num = comptime "0123456789";
                const alphanum = alpha ++ num;

                const index =
                    if (std.mem.indexOfNonePos(u8, self.source, self.current, alphanum))
                        |idx| idx 
                    else
                        self.end;

                self.current = @intCast(index);

                break :blk self.addToken(.EnumLiteral);
            }
            else {
                self.report("Unexpected character {c}", .{ch});
                break :blk error.UnexpectedCharacter;
            }
        },
        else => |ch| {
            if (std.ascii.isDigit(ch)) {
                while (std.ascii.isDigit(self.peek())) {
                    _ = self.advance();
                }

                if (self.check('.') and std.ascii.isDigit(self.peekn(1))) {
                    _ = self.advance();

                    while (std.ascii.isDigit(self.peek())) {
                        _ = self.advance();
                    }

                    break :blk self.addToken(.Float);
                }
                else if (self.check('.')) {
                    _ = self.advance();
                    self.report("Trailing dots (.) after numeric literals are not allowed.", .{});
                    break :blk error.DotPostfixedNumericLiteral;
                }

                break :blk self.addToken(.Integer);
            }
            else if (std.ascii.isAlphabetic(ch) or ch == '_'){
                const alpha = comptime "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz_";
                const num = comptime "0123456789";
                const alphanum = alpha ++ num;

                const index =
                    if (std.mem.indexOfNonePos(u8, self.source, self.current, alphanum))
                        |idx| idx 
                    else
                        self.end;

                self.current = @intCast(index);

                const str = self.source[self.start..self.current];
                break :blk self.addToken(getType(str));
            }
            else {
                self.report("Unexpected character {c}", .{ch});
                return error.UnexpectedCharacter;
            }
        }
    };
}

//
// Helpers
//

fn allocator(self: *Lexer) std.mem.Allocator {
    return self.arena.allocator();
}

fn skipWhitespace(self: *Lexer) void {
    const index =
        if(std.mem.indexOfNonePos(u8, self.source, self.current, " \n\t\r")) |idx|
            idx
        else
            self.end;

    self.current = @intCast(index);

//        while (self.current < self.end) {
//            switch (self.source[self.current]) {
//                ' ', '\t', '\r', '\n' => {
//                    self.current += 1;
//                },
//                else => return,
//            }
//        }
}

fn check(self: *const Lexer, expected: u8) bool {
    return
        if (self.isAtEnd()) false
        else self.source[self.current] == expected;
}

fn match(self: *Lexer, expected: u8) bool {
    if (self.isAtEnd()) return false;
    if (self.source[self.current] != expected) return false;

    _ = self.advance();
    return true;
}

fn previous(self: *const Lexer) u8 {
    return
        if (self.current <= 0) 0
        else self.source[self.current-1];
}

fn peek(self: *const Lexer) u8 {
    return
        if (self.isAtEnd()) 0
        else self.source[self.current];
}

fn peekn(self: *const Lexer, n: u32) u8 {
    return
        if (self.current + n >= self.source.len) 0
        else self.source[self.current + n];
}

fn advance(self: *Lexer) u8 {
    defer self.current += 1;
    return self.source[self.current];
}

fn consume(self: *Lexer, expected: u8, message: []const u8) common.CompilerError!u8 {
    if (self.peek() == expected) return self.advance();

    self.report("{s}\n\tExpected '{c}' got '{c}'", .{message, expected, self.peek()});
    return error.UnexpectedCharacter;
}

fn addToken(self: *Lexer, tokenType: TokenType) common.CompilerError!void {
    self.tokens.append(self.allocator(), .{
        .type = tokenType,
        .start = self.start,
        .end = self.current,
    }) catch return error.InvalidToken;

    if (tokenType == .String)
        _ = self.advance();
}

fn isAtEnd(self: *const Lexer) bool {
    return self.current >= self.end;
}

fn getType(str: []const u8) TokenType {
    return
        if (keywords.get(str)) |keyword| keyword 
        else .Identifier;
}

fn report(self: *Lexer, comptime fmt: []const u8, args: anytype) void {
    const errToken = Token {
        .type = .EOF,
        .start = self.start,
        .end = self.start + 1,
    };
    const pos = errToken.position(self.context, self.file);

    common.log.err("[LEXER ERROR] ", .{});
    common.log.err(fmt, args);
    common.log.err("\t{s} {d}:{d}\n", .{self.context.getFileName(self.file), pos.line, pos.column});
}

//
// Tests
//
pub const Tests = struct {
    var debugAllocator = std.heap.DebugAllocator(.{}){};
    const gpa = debugAllocator.allocator();

    test "Enum Litaral" {
        var context = try common.CompilerContext.init(gpa);
        var lexer = try init(gpa, &context, "test/enum_literal.jasl");
        const _tokens = try lexer.lex();
        const tokens = context.getTokens(_tokens);

        try std.testing.expectEqual(.EnumLiteral, tokens.items(.type)[1]);
    }
};
