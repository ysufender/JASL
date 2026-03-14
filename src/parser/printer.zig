const std = @import("std");
const lexer = @import("../lexer/lexer.zig");
const common = @import("../core/common.zig");

const ps = @import("parser.zig"); 

pub const PrettyPrinter = struct {
    const Self = @This();

    parser: *const ps.Parser,
    indent_level: u32 = 0,

    pub fn init(parser: *const ps.Parser) Self {
        return .{
            .parser = parser,
        };
    }

    fn printIndent(self: *Self) !void {
        for (0..self.indent_level * 4) |_| {
            std.debug.print(" ", .{});
        }
    }

    pub fn printStatement(self: *Self, ptr: ps.StatementPtr) !void {
        const stmt = self.parser.statementMap.get(ptr);
        switch (stmt.type) {
            .Block => {
                std.debug.print("{{\n", .{});
                self.indent_level += 1;
                
                
                const start_idx = stmt.value;
                const range_start = self.parser.extra.items[start_idx];
                const range_end = self.parser.extra.items[start_idx + 1];
                
                var i = range_start;
                while (i < range_end) : (i += 1) {
                    try self.printIndent();
                    try self.printStatement(self.parser.extra.items[i]);
                    std.debug.print("\n", .{});
                }

                self.indent_level -= 1;
                try self.printIndent();
                std.debug.print("}}", .{});
            },
            .Return => {
                std.debug.print("return ", .{});
                try self.printExpression(stmt.value);
                std.debug.print(";", .{});
            },
            .VariableDefinition => {
                const base = stmt.value;
                const sig_start = self.parser.extra.items[base];
                const sig_end = self.parser.extra.items[base + 1];
                const expr_ptr = self.parser.extra.items[base + 2];

                std.debug.print("let ", .{});
                var i = sig_start;
                while (i < sig_end) : (i += 1) {
                    try self.printSignature(self.parser.extra.items[i]);
                    if (i + 1 < sig_end) std.debug.print(", ", .{});
                }
                std.debug.print(" = ", .{});
                try self.printExpression(expr_ptr);
                std.debug.print(";", .{});
            },
            .FunctionDefinition => {
                const base = stmt.value;
                const is_pub = self.parser.extra.items[base] != 0;
                const name_tok = self.parser.extra.items[base + 1];
                const p_start = self.parser.extra.items[base + 2];
                const p_end = self.parser.extra.items[base + 3];
                const r_start = self.parser.extra.items[base + 4];
                const r_end = self.parser.extra.items[base + 5];
                const body_ptr = self.parser.extra.items[base + 6];

                if (is_pub) std.debug.print("pub ", .{});
                std.debug.print("fn {s}(", .{self.getLexeme(name_tok)});
                
                var i = p_start;
                while (i < p_end) : (i += 1) {
                    try self.printSignature(self.parser.extra.items[i]);
                    if (i + 1 < p_end) std.debug.print(", ", .{});
                }
                std.debug.print(") -> ", .{});
                
                i = r_start;
                while (i < r_end) : (i += 1) {
                    try self.printExpression(self.parser.extra.items[i]);
                    if (i + 1 < r_end) std.debug.print(", ", .{});
                }
                std.debug.print(" ", .{});
                try self.printStatement(body_ptr);
            },
            .While => {
                const base = stmt.value;
                std.debug.print("while ", .{});
                try self.printExpression(self.parser.extra.items[base]);
                std.debug.print(" ", .{});
                try self.printStatement(self.parser.extra.items[base + 1]);
            },
            .Conditional => {
                const base = stmt.value;
                std.debug.print("if ", .{});
                try self.printExpression(self.parser.extra.items[base]);
                std.debug.print(" ", .{});
                try self.printStatement(self.parser.extra.items[base + 1]);
                if (self.parser.extra.items[base + 2] != 0) {
                    std.debug.print(" else ", .{});
                    try self.printStatement(self.parser.extra.items[base + 3]);
                }
            },
            .Namespace => {
                std.debug.print("namespace ", .{});
                try self.printExpression(stmt.value);
                std.debug.print(";", .{});
            },
            .Include => {
                std.debug.print("include {s};", .{self.getLexeme(stmt.value)});
            },
            .InlineAssembly => {
                std.debug.print("asm {s};", .{self.getLexeme(stmt.value)});
            },
            .Break => std.debug.print("break;", .{}),
            .Continue => std.debug.print("continue;", .{}),
            .Discard => {
                std.debug.print("_ = ", .{});
                try self.printExpression(stmt.value);
                std.debug.print(";", .{});
            },
        }
    }

    

    pub fn printExpression(self: *Self, ptr: ps.ExpressionPtr) !void {
        const expr = self.parser.expressionMap.get(ptr);
        switch (expr.type) {
            .Literal, .Identifier => {
                std.debug.print("{s}", .{self.getLexeme(expr.value.DirectPtr)});
            },
            .Binary => {
                const base = expr.value.DirectPtr;
                std.debug.print("(", .{});
                try self.printExpression(self.parser.extra.items[base]);
                std.debug.print(" {s} ", .{@tagName(@as(lexer.TokenType, @enumFromInt(self.parser.extra.items[base+1])))});
                try self.printExpression(self.parser.extra.items[base+2]);
                std.debug.print(")", .{});
            },
            .Unary => {
                const base = expr.value.DirectPtr;
                std.debug.print("{s}", .{@tagName(@as(lexer.TokenType, @enumFromInt(self.parser.extra.items[base])))});
                try self.printExpression(self.parser.extra.items[base+1]);
            },
            .Call => {
                const base = expr.value.DirectPtr;
                try self.printExpression(self.parser.extra.items[base]);
                std.debug.print("(", .{});
                const start = self.parser.extra.items[base + 1];
                const end = self.parser.extra.items[base + 2];
                var i = start;
                while (i < end) : (i += 1) {
                    try self.printExpression(self.parser.extra.items[i]);
                    if (i + 1 < end) std.debug.print(", ", .{});
                }
                std.debug.print(")", .{});
            },
            .Dot, .Scoping => {
                const base = expr.value.DirectPtr;
                const op = if (expr.type == .Dot) "." else "::";
                try self.printExpression(self.parser.extra.items[base]);
                std.debug.print("{s}{s}", .{op, self.getLexeme(self.parser.extra.items[base+1])});
            },
            .Indexing => {
                const base = expr.value.DirectPtr;
                try self.printExpression(self.parser.extra.items[base]);
                std.debug.print("[", .{});
                try self.printExpression(self.parser.extra.items[base+1]);
                std.debug.print("]", .{});
            },
            .PointerType => {
                std.debug.print("*", .{});
                try self.printExpression(expr.value.DirectPtr);
            },
            .MutableType => {
                std.debug.print("mut ", .{});
                try self.printExpression(expr.value.DirectPtr);
            },
            .SliceType => {
                std.debug.print("[]", .{});
                try self.printExpression(expr.value.DirectPtr);
            },
            .Conditional => { 
                const base = expr.value.DirectPtr;
                std.debug.print("if ", .{});
                try self.printExpression(self.parser.extra.items[base]);
                std.debug.print(" ", .{});
                try self.printExpression(self.parser.extra.items[base+1]);
                std.debug.print(" else ", .{});
                try self.printExpression(self.parser.extra.items[base+2]);
            },
            else => std.debug.print("<expr:{s}>", .{@tagName(expr.type)}),
        }
    }

    fn printSignature(self: *Self, ptr: u32) !void {
        const sig = self.parser.signaturePool.get(ptr);
        std.debug.print("{s}: ", .{self.getLexeme(sig.name)});
        try self.printExpression(sig.type);
    }

    fn getLexeme(self: *Self, token_idx: u32) []const u8 {
        return self.parser.tokens.get(token_idx).lexeme(self.parser.file);
    }
};
