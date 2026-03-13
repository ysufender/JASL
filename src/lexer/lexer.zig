const std = @import("std");
const common = @import("../core/common.zig");
const platform = @import("../core/platform.zig");
const arraylist = @import("../util/arraylist.zig");

pub const TokenList = arraylist.MultiArrayList(Token);

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
    Include, Namespace,
    If, Else, While,
    Return, Defer, Extern,
    Break, Continue,
    Fn, Layout, Let, 
    Asm,
    Pub, Mut,
    And, Or,
    Identifier,
    String, Integer, Float, False, True, Nullptr,
    Discard,
    EOF,
};

pub const Position = struct {
    line: u32,
    column: u32,
};

pub const Token = struct {
    type: TokenType,
    start: u32,
    end: u32,

    const Self = @This();

    pub const eof: Self = .{
        .type = .EOF,
        .start = 0,
        .end = 0,
    };

    pub fn toString(self: *const Self, allocator: std.mem.Allocator, file: u32) []const u8 {
        const lex = self.lexeme(file);
        const length =  @tagName(self.type).len + lex.len + 4;
        const buffer = allocator.alloc(u8, length) catch return "";
        return std.fmt.bufPrint(buffer, "<{s}: {s}>", .{@tagName(self.type), lex}) catch unreachable;
    }

    pub fn lexeme(self: *const Self, file: u32) []const u8 {
        return common.CompilerContext.fileMap[file][self.start..self.end];
    }

    pub fn position(self: *const Self, file: u32) Position {
        const source = common.CompilerContext.fileMap[file][0..self.start];
        var line: u32 = 1;
        var col: u32 = 0;

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

pub const Scanner = struct {
    const Self = @This();
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
        .{ "include", .Include },
        .{ "namespace", .Namespace },
        .{ "false", .False },
        .{ "true", .True },
        .{ "nullptr", .Nullptr },
        .{ "layout", .Layout },
        .{ "pub", .Pub },
        .{ "mut", .Mut },
        .{ "asm", .Asm },
        .{ "break", .Break },
        .{ "continue", .Continue },
        .{ "_", .Discard },
    });

    tokens: TokenList,
    file: u32,
    source: []const u8,

    start: u32,
    current: u32,
    end: u32,

    arena: std.heap.ArenaAllocator,

    //
    // Public API
    //

    pub fn init(base: std.mem.Allocator, file: u32) common.CompilerError!Self {
        const src = common.CompilerContext.fileMap[file];
        const len: u32 = @intCast(src.len);

        var arena = std.heap.ArenaAllocator.init(base);
        var tokens = try TokenList.init(arena.allocator(), len + 2);

        tokens.appendAssumeCapacity(.{
            .type = .Semicolon,
            .start = file,
            .end = file,
        });
        
        var self = Self{
            .start = 0,
            .current = 0,
            .end = len,
            .file = file,
            .source = src,
            .arena = arena,
            .tokens = tokens,
        };

        self.skipWhitespace();
        return self;
    }

    pub fn scanAll(self: *Self) common.CompilerError!TokenList {
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

        return self.tokens;
    }

    pub fn scan(self: *Self) common.CompilerError!Token {
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

    fn scanToken(self: *Self) common.CompilerError!void {
        self.start = self.current;

        return switch (self.advance()) {
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
                    return error.DotPrefixedNumericLiteral;
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
                        return error.UnterminatedComment;
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
            '"' => {
                const index =
                    if (std.mem.indexOfScalarPos(u8, self.source, self.current, '"'))
                        |idx| idx
                    else
                        self.end;

                self.current = @intCast(index);

                if (self.isAtEnd()) {
                    self.report("Unterminated string literal", .{});
                    return error.UnterminatedStringLiteral;
                }

                self.start += 1;
                try self.addToken(.String);
            },
            // TODO: character literals
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

                        return self.addToken(.Float);
                    }
                    else if (self.check('.')) {
                        _ = self.advance();
                        self.report("Trailing dots (.) after numeric literals are not allowed.", .{});
                        return error.DotPostfixedNumericLiteral;
                    }

                    return self.addToken(.Integer);
                }
                else if (std.ascii.isAlphabetic(ch) or ch == '_'){
                    const alpha = comptime "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";
                    const num = comptime "0123456789";
                    const alphanum = alpha ++ num;

                    const index =
                        if (std.mem.indexOfNonePos(u8, self.source, self.current, alphanum))
                            |idx| idx 
                        else
                            self.end;

                    self.current = @intCast(index);

                    const str = self.source[self.start..self.current];
                    return self.addToken(getType(str));
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

    fn allocator(self: *Self) std.mem.Allocator {
        return self.arena.allocator();
    }

    fn skipWhitespace(self: *Self) void {
        const index = if(std.mem.indexOfNonePos(u8, self.source, self.current, " \n\t\r")) |idx| idx
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

    fn peekn(self: *Self, n: u32) u8 {
        if (self.current + n >= self.source.len) return 0;
        return self.source[self.current + n];
    }

    fn advance(self: *Self) u8 {
        self.current += 1;
        return self.source[self.current-1];
    }

    fn addToken(self: *Self, tokenType: TokenType) common.CompilerError!void {
        self.tokens.append(self.allocator(), .{
            .type = tokenType,
            .start = self.start,
            .end = self.current,
        }) catch return error.InvalidToken;

        if (tokenType == .String)
            _ = self.advance();
    }

    fn isAtEnd(self: *Self) bool {
        return self.current >= self.end;
    }

    fn getType(str: []const u8) TokenType {
        return
            if (keywords.get(str)) |keyword| keyword 
            else .Identifier;
    }

    fn report(self: *Self, comptime fmt: []const u8, args: anytype) void {
        const errToken = Token {
            .type = .EOF,
            .start = self.start,
            .end = self.start + 1,
        };
        const pos = errToken.position(self.file);

        common.log.err("[LEXER ERROR] ", .{});
        common.log.err(fmt, args);
        common.log.err("\t{s} {d}:{d}\n", .{common.CompilerContext.filenameMap[self.file], pos.line, pos.column});
    }
};

pub const StreamingScanner = struct {
    const Self = @This();

    inner: Scanner,

    pub fn init(base: std.mem.Allocator, file: u32) common.CompilerError!Self {
        return .{
            .inner = Scanner.init(base, file),
        };
    }

    pub fn requestToken(self: *Self) common.CompilerError!Token {
        return self.inner.scan();
    }
};

//
// Tests
//
pub const Tests = struct {
};
