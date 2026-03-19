const std = @import("std");
const lexer = @import("../lexer/lexer.zig");
const common = @import("../core/common.zig");

const parser = @import("parser.zig"); 

pub const PrettyPrinter = struct {
    const Self = @This();

    table: *const parser.AST,
    indent_level: u32 = 0,

    pub fn init(table: *const parser.AST) Self {
        return .{
            .table = table,
        };
    }

    fn printIndent(self: *Self) !void {
        for (0..self.indent_level * 4) |_| {
            std.debug.print(" ", .{});
        }
    }

    pub fn printStatement(self: *Self, ptr: parser.StatementPtr) !void {
        const stmt = self.table.statements.get(ptr);
        switch (stmt.type) {
            .Block => {
                std.debug.print("{{\n", .{});
                self.indent_level += 1;
                
                
                const start_idx = stmt.value;
                const range_start = self.table.extra.items[start_idx];
                const range_end = self.table.extra.items[start_idx + 1];
                
                var i = range_start;
                while (i < range_end) : (i += 1) {
                    try self.printIndent();
                    try self.printStatement(self.table.extra.items[i]);
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
                const sig_start = self.table.extra.items[base];
                const sig_end = self.table.extra.items[base + 1];
                const expr_ptr = self.table.extra.items[base + 2];

                std.debug.print("let ", .{});
                var i = sig_start;
                while (i < sig_end) : (i += 1) {
                    try self.printSignature(self.table.extra.items[i]);
                    if (i + 1 < sig_end) std.debug.print(", ", .{});
                }
                std.debug.print(" = ", .{});
                try self.printExpression(expr_ptr);
                std.debug.print(";", .{});
            },
            .While => {
                const base = stmt.value;
                std.debug.print("while ", .{});
                try self.printExpression(self.table.extra.items[base]);
                std.debug.print(" ", .{});
                try self.printStatement(self.table.extra.items[base + 1]);
            },
            .Conditional => {
                const base = stmt.value;
                std.debug.print("if ", .{});
                try self.printExpression(self.table.extra.items[base]);
                std.debug.print(" ", .{});
                try self.printStatement(self.table.extra.items[base + 1]);
                if (self.table.extra.items[base + 2] != 0) {
                    std.debug.print(" else ", .{});
                    try self.printStatement(self.table.extra.items[base + 3]);
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
            .FunctionDefinition => {
                const base = stmt.value;
                const public = self.table.extra.items[base] == 1;
                const name = self.table.extra.items[base + 1];
                const p_start = self.table.extra.items[base + 2];
                const p_end = self.table.extra.items[base + 3];
                const returns = self.table.extra.items[base + 4];
                const body_ptr = self.table.extra.items[base + 5];

                std.debug.print("{s}fn {s}(", .{
                    if (public) "pub " else "",
                    self.table.tokens.get(name).lexeme(self.table.tokens.items(.start)[0]),
                });
                var i = p_start;
                while (i < p_end) : (i += 1) {
                    try self.printSignature(self.table.extra.items[i]);
                    if (i + 1 < p_end) std.debug.print(", ", .{});
                }
                std.debug.print(") -> ", .{});
                
                try self.printExpression(returns);
                std.debug.print(" ", .{});
                try self.printStatement(body_ptr);
            },

            .Break => std.debug.print("break;", .{}),
            .Continue => std.debug.print("continue;", .{}),
            .Discard => {
                std.debug.print("_ = ", .{});
                try self.printExpression(stmt.value);
                std.debug.print(";", .{});
            },
            .Expression => {
                try self.printExpression(stmt.value);
                std.debug.print(";", .{});
            }
        }
    }

    pub fn printExpression(self: *Self, ptr: parser.ExpressionPtr) common.CompilerError!void {
        const expr = self.table.expressions.get(ptr);
        switch (expr.type) {
            .Literal, .Identifier => {
                std.debug.print("{s}", .{self.getLexeme(expr.value.DirectPtr)});
            },
            .Binary => {
                const base = expr.value.DirectPtr;
                try self.printExpression(self.table.extra.items[base]);
                std.debug.print(" {s} ", .{@tagName(@as(lexer.TokenType, @enumFromInt(self.table.extra.items[base+1])))});
                try self.printExpression(self.table.extra.items[base+2]);
            },
            .Unary => {
                const base = expr.value.DirectPtr;
                std.debug.print("{s}", .{@tagName(@as(lexer.TokenType, @enumFromInt(self.table.extra.items[base])))});
                try self.printExpression(self.table.extra.items[base+1]);
            },
            .Call => {
                const base = expr.value.DirectPtr;
                try self.printExpression(self.table.extra.items[base]);
                std.debug.print("(", .{});
                const start = self.table.extra.items[base + 1];
                const end = self.table.extra.items[base + 2];
                var i = start;
                while (i < end) : (i += 1) {
                    try self.printExpression(self.table.extra.items[i]);
                    if (i + 1 < end) std.debug.print(", ", .{});
                }
                std.debug.print(")", .{});
            },
            .Dot, .Scoping => {
                const base = expr.value.DirectPtr;
                const op = if (expr.type == .Dot) "." else "::";
                try self.printExpression(self.table.extra.items[base]);
                std.debug.print("{s}{s}", .{op, self.getLexeme(self.table.extra.items[base+1])});
            },
            .Indexing => {
                const base = expr.value.DirectPtr;
                try self.printExpression(self.table.extra.items[base]);
                std.debug.print("[", .{});
                try self.printExpression(self.table.extra.items[base+1]);
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
            .ValueType => {
                const base = expr.value.DirectPtr;
                const defined = if (self.table.extra.items[base] == @intFromBool(true)) true else false;
                const token = self.table.extra.items[base + @as(u32, if (defined) 1 else 0)];

                if (defined) {
                    std.debug.print("{s}", .{self.table.tokens.get(token).lexeme(self.table.tokens.items(.start)[0])});
                }
                else {
                    std.debug.print("any", .{});
                }
            },
            .Conditional => { 
                const base = expr.value.DirectPtr;
                std.debug.print("if ", .{});
                try self.printExpression(self.table.extra.items[base]);
                std.debug.print(" ", .{});
                try self.printExpression(self.table.extra.items[base+1]);
                std.debug.print(" else ", .{});
                try self.printExpression(self.table.extra.items[base+2]);
            },
            .StructDefinition => {
                const base = expr.value.DirectPtr;
                const varStart = self.table.extra.items[base];
                const varEnd = self.table.extra.items[base+1];
                const defStart = self.table.extra.items[base+2];
                const defEnd = self.table.extra.items[base+3];

                std.debug.print("struct {{\n", .{});
                self.indent_level += 1;

                for (varStart..varEnd) |i| {
                    try self.printIndent();
                    try self.printSignature(self.table.extra.items[i]);
                    std.debug.print(",\n", .{});
                }

                std.debug.print("\n", .{});

                for (defStart..defEnd) |i| {
                    try self.printIndent();
                    try self.printStatement(self.table.extra.items[i]);
                    std.debug.print("\n", .{});
                }

                self.indent_level -= 1;
                try self.printIndent();
                std.debug.print("}}", .{});
            },
            .FunctionType => {
                const base = expr.value.DirectPtr;
                const p_start = self.table.extra.items[base + 1];
                const p_end = self.table.extra.items[base + 3];
                const returns = self.table.extra.items[base + 4];

                std.debug.print("fn (", .{});
                var i = p_start;
                while (i < p_end) : (i += 1) {
                    try self.printSignature(self.table.extra.items[i]);
                    if (i + 1 < p_end) std.debug.print(", ", .{});
                }
                std.debug.print(") -> ", .{});
                try self.printExpression(returns);
            },
            .ExpressionList => {
                std.debug.print("Expression lists are not supported in C", .{});
                return error.InternalError;
            },
        }
    }

    fn printSignature(self: *Self, ptr: u32) common.CompilerError!void {
        const sig = self.table.signatures.get(ptr);
        std.debug.print("{s}: ", .{self.getLexeme(sig.name)});
        self.printExpression(sig.type) catch return error.InternalError;
    }

    fn getLexeme(self: *Self, token_idx: u32) []const u8 {
        return self.table.tokens.get(token_idx).lexeme(self.table.tokens.items(.start)[0]);
    }
};
