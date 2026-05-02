const std = @import("std");
const common = @import("../core/common.zig");
const collections = @import("../util/collections.zig");
const defines = @import("../core/defines.zig");

const assert = std.debug.assert;

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
    If, Else, While, For,
    Switch,
    Return, Defer,
    Break, Continue,
    Fn, Struct, Let, Enum, Union,
    Asm,
    Pub, Mut,
    And, Or, Mark,
    Identifier,
    String, Integer, Float, False, True, EnumLiteral,
    Discard,
    Range,
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

    pub fn toString(lexer: *const Token, gpa: std.mem.Allocator, context: *const common.CompilerContext, file: defines.FilePtr) []const u8 {
        const string = lexer.lexeme(context, file);
        const length =  @tagName(lexer.type).len + string.len + 16;
        const pos = lexer.position(context, file);
        const buffer = gpa.alloc(u8, length) catch return @errorName(error.AllocatorFailure);
        return std.fmt.bufPrint(buffer, "<{s}: {s} at ({d}:{d})>", .{
            @tagName(lexer.type),
            string,
            pos.line,
            pos.column,
        }) catch unreachable;
    }

    pub fn lexeme(lexer: *const Token, context: *const common.CompilerContext, file: defines.FilePtr) []const u8 {
        assert(lexer.start <= lexer.end);

        return context.getFile(file)[lexer.start..lexer.end];
    }

    pub fn position(lexer: *const Token, context: *const common.CompilerContext, file: defines.FilePtr) Position {
        var source = context.getFile(file)[0..lexer.start];

        var line: defines.Offset = 1;
        while (std.mem.indexOfScalar(u8, source, '\n')) |newline| {
            source = source[(newline + 1)..];
            line += 1;
        }

        const col: defines.Offset = @intCast(source.len + 1);

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
    .{ "for", .For },
    .{ "fn", .Fn },
    .{ "return", .Return },
    .{ "defer", .Defer },
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
    .{ "#", .Mark },
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
        .type = .Identifier,
        .start = fileHandle,
        .end = fileHandle,
    });
    
    var lexer = Lexer{
        .start = 0,
        .current = 0,
        .end = len,
        .file = fileHandle,
        .source = src,
        .arena = arena,
        .tokens = tokens,
        .context = context,
    };

    lexer.skipWhitespace();
    return lexer;
}

pub fn lex(lexer: *Lexer) common.CompilerError!defines.TokenListPtr {
    while (!lexer.isAtEnd()) {
        try lexer.scanToken();
        lexer.skipWhitespace();
    }

    lexer.tokens.append(
        lexer.allocator(),
        .{
            .type = .EOF,
            .start = lexer.start,
            .end = lexer.current,
        }
    ) catch return error.InternalError;

    lexer.start = 0;
    lexer.current = 0;

    return lexer.context.registerTokens(lexer.tokens.slice());
}

pub fn lexToken(lexer: *Lexer) common.CompilerError!Token {
    if (lexer.isAtEnd()) {
        return .{
            .type = .EOF,
            .start = lexer.end,
            .end = lexer.end,
        };
    }
    else {
        try lexer.scanToken();
        assert(lexer.tokens.len > 0);
        return lexer.tokens[lexer.tokens.len - 1];
    }
}

//
// Private Implementation
//

fn scanToken(lexer: *Lexer) common.CompilerError!void {
    lexer.start = lexer.current;

    return blk: switch (lexer.advance()) {
        '(' => lexer.addToken(.LParen),
        ')' => lexer.addToken(.RParen),
        '{' => lexer.addToken(.LBrace),
        '}' => lexer.addToken(.RBrace),
        '[' => lexer.addToken(.LBracket),
        ']' => lexer.addToken(.RBracket),
        ',' => lexer.addToken(.Comma),
        '~' => lexer.addToken(.Tilde),
        '^' => lexer.addToken(.Xor),
        '.' => 
            if (std.ascii.isDigit(lexer.peek())) {
                lexer.report("Dot (.) prefixed numeric literals are not allowed.", .{});
                break :blk error.DotPrefixedNumericLiteral;
            }
            else if (lexer.match('.')) lexer.addToken(.Range) 
            else lexer.addToken(.Dot),
        ':' =>
            if (lexer.match(':')) lexer.addToken(.DoubleColon)
            else lexer.addToken(.Colon),
        ';' => lexer.addToken(.Semicolon),
        '-' => 
            if (lexer.match('>')) lexer.addToken(.Arrow)
            else lexer.addToken(.Minus),
        '+' => lexer.addToken(.Plus),
        '/' => 
            if (lexer.match('/')) {
                const index =
                    if (std.mem.indexOfScalarPos(u8, lexer.source, lexer.current, '\n'))
                        |idx| idx
                    else
                        lexer.end;

                lexer.current = @intCast(index);
            }
            else if (lexer.match('*')) {
                var ident: u32 = 1;

                // Rewrite SIMD
                while (ident > 0 and !lexer.isAtEnd()) {
                    const ch = lexer.advance();

                    if (ch == '*' and lexer.match('/')) {
                        ident -= 1;
                    }
                    else if (ch == '/' and lexer.match('*')) {
                        ident += 1;
                   }
                }

                if (lexer.isAtEnd()) {
                    lexer.report("Unterminated multiline comment", .{});
                    break :blk error.UnterminatedComment;
                }
            }
            else lexer.addToken(.Slash),
        '*' => lexer.addToken(.Star),
        '!' =>
            if (lexer.match('=')) lexer.addToken(.BangEqual)
            else lexer.addToken(.Bang),
        '=' =>
            if (lexer.match('=')) lexer.addToken(.EqualEqual)
            else lexer.addToken(.Equal),
        '>' =>
            if (lexer.match('=')) lexer.addToken(.GreaterEqual)
            else if (lexer.match('>')) lexer.addToken(.RightShift)
            else lexer.addToken(.Greater),
        '<' =>
            if (lexer.match('=')) lexer.addToken(.LesserEqual)
            else if (lexer.match('<')) lexer.addToken(.LeftShift)
            else lexer.addToken(.Lesser),
        '|' => lexer.addToken(.Pipe),
        '&' => lexer.addToken(.Ampersand),
        '\'' => {
            const ch = lexer.advance();

            if (ch == '\'') {
                lexer.report("Empty character literals are not allowed.", .{});
                break :blk error.EmptyCharLiteral;
            }

            _ = try lexer.consume('\'', "Expected closing single quote (')");
            lexer.start += 1;
            try lexer.addToken(.Integer);
        },
        '"' => {
            const index =
                if (std.mem.indexOfScalarPos(u8, lexer.source, lexer.current, '"'))
                    |idx| idx
                else
                    lexer.end;

            lexer.current = @intCast(index);

            if (lexer.isAtEnd()) {
                lexer.report("Unterminated string literal", .{});
                break :blk error.UnterminatedStringLiteral;
            }

            lexer.start += 1;
            try lexer.addToken(.String);
        },
        '@' => {
            const ch = lexer.advance();
            if (std.ascii.isAlphabetic(ch) or ch == '_'){
                const alpha = comptime "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz_";
                const num = comptime "0123456789";
                const alphanum = comptime (alpha ++ num);

                const index =
                    if (std.mem.indexOfNonePos(u8, lexer.source, lexer.current, alphanum))
                        |idx| idx 
                    else
                        lexer.end;

                lexer.current = @intCast(index);

                break :blk lexer.addToken(.EnumLiteral);
            }
            else {
                lexer.report("Unexpected character {c}", .{ch});
                break :blk error.UnexpectedCharacter;
            }
        },
        else => |ch| {
            const alpha = comptime "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz_#";
            const num = comptime "0123456789";
            const alphanum = comptime (alpha ++ num);

            if (std.mem.containsAtLeastScalar(u8, num, 1, ch)) {
                while (std.mem.containsAtLeastScalar(u8, num, 1, lexer.peek())) {
                    _ = lexer.advance();
                }

                if (lexer.check('.') and std.mem.containsAtLeastScalar(u8, num, 1, lexer.peekn(1))) {
                    _ = lexer.advance();

                    while (std.mem.containsAtLeastScalar(u8, num, 1, lexer.peek())) {
                        _ = lexer.advance();
                    }

                    break :blk lexer.addToken(.Float);
                }
                //else if (lexer.check('.')) {
                //    _ = lexer.advance();
                //    lexer.report("Trailing dots (.) after numeric literals are not allowed.", .{});
                //    break :blk error.DotPostfixedNumericLiteral;
                //}

                break :blk lexer.addToken(.Integer);
            }
            else if (std.mem.containsAtLeastScalar(u8, alpha, 1, ch) or ch == '_'){
                const index =
                    if (std.mem.indexOfNonePos(u8, lexer.source, lexer.current, alphanum))
                        |idx| idx 
                    else
                        lexer.end;

                lexer.current = @intCast(index);

                const str = lexer.source[lexer.start..lexer.current];
                break :blk lexer.addToken(getType(str));
            }
            else {
                lexer.report("Unexpected character {c}", .{ch});
                return error.UnexpectedCharacter;
            }
        }
    };
}

//
// Helpers
//

fn allocator(lexer: *Lexer) std.mem.Allocator {
    return lexer.arena.allocator();
}

fn skipWhitespace(lexer: *Lexer) void {
    const index =
        if(std.mem.indexOfNonePos(u8, lexer.source, lexer.current, " \n\t\r")) |idx|
            idx
        else
            lexer.end;

    lexer.current = @intCast(index);
}

fn check(lexer: *const Lexer, expected: u8) bool {
    return
        if (lexer.isAtEnd()) false
        else lexer.source[lexer.current] == expected;
}

fn match(lexer: *Lexer, expected: u8) bool {
    if (lexer.isAtEnd()) return false;
    if (lexer.source[lexer.current] != expected) return false;

    _ = lexer.advance();
    return true;
}

fn previous(lexer: *const Lexer) u8 {
    assert(lexer.current > 0);
    return lexer.source[lexer.current-1];
}

fn peek(lexer: *const Lexer) u8 {
    return
        if (lexer.isAtEnd()) 0
        else lexer.source[lexer.current];
}

fn peekn(lexer: *const Lexer, n: u32) u8 {
    assert(lexer.current + n < lexer.source.len);
    return lexer.source[lexer.current + n];
}

fn advance(lexer: *Lexer) u8 {
    defer lexer.current += 1;
    return lexer.source[lexer.current];
}

fn consume(lexer: *Lexer, expected: u8, message: []const u8) common.CompilerError!u8 {
    if (lexer.peek() == expected) return lexer.advance();

    lexer.report("{s}\n\tExpected '{c}' got '{c}'", .{message, expected, lexer.peek()});
    return error.UnexpectedCharacter;
}

fn addToken(lexer: *Lexer, tokenType: TokenType) common.CompilerError!void {
    lexer.tokens.append(lexer.allocator(), .{
        .type = tokenType,
        .start = lexer.start,
        .end = lexer.current,
    }) catch return error.InvalidToken;

    if (tokenType == .String)
        _ = lexer.advance();
}

fn isAtEnd(lexer: *const Lexer) bool {
    return lexer.current >= lexer.end;
}

fn getType(str: []const u8) TokenType {
    return
        if (keywords.get(str)) |keyword| keyword 
        else .Identifier;
}

fn report(lexer: *Lexer, comptime fmt: []const u8, args: anytype) void {
    const errToken = Token {
        .type = .EOF,
        .start = lexer.start,
        .end = lexer.start + 1,
    };
    const pos = errToken.position(lexer.context, lexer.file);

    common.log.err(fmt, args);
    common.log.err(("." ** 4) ++ " In {s} {d}:{d}", .{lexer.context.getFileName(lexer.file), pos.line, pos.column});
}

//
// Tests
//
pub const Tests = struct {
    var debugAllocator = std.heap.DebugAllocator(.{}){};
    const gpa = debugAllocator.allocator();

    test "All" {
    }
};
