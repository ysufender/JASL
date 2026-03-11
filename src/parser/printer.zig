const std = @import("std");
const lexer = @import("../lexer/lexer.zig");
const Parser = @import("parser.zig").Parser;
const common = @import("../core/common.zig");
const TokenType = lexer.TokenType;

pub const PrettyPrinter = struct {
    parser: *const Parser,
    writer: std.Io.Writer,
    indent_level: usize = 0,

    const Self = @This();

    pub fn init(parser: *const Parser, writer: std.Io.Writer) Self {
        return .{
            .parser = parser,
            .writer = writer,
        };
    }

    fn indent(self: *Self) common.CompilerError!void {
        var i: usize = 0;
        while (i < self.indent_level) : (i += 1) {
            self.writer.writeAll("    ") catch return error.InternalError;
        }
    }

    pub fn printAll(self: *Self) common.CompilerError!void {
        for (0..self.parser.statementMap.len) |i| {
            try self.printStatement(@intCast(i));
            self.writer.writeAll("\n") catch return error.InternalError;
        }
    }

    pub fn printStatement(self: *Self, ptr: u32) common.CompilerError!void {
        const stmt = self.parser.statementMap.get(ptr);
        switch (stmt) {
            .Block => |start| {
                const block_start = self.parser.extra.items[start];
                const block_end = self.parser.extra.items[start + 1];
                
                self.writer.writeAll("{\n") catch return error.InternalError;
                self.indent_level += 1;
                for (block_start..block_end) |i| {
                    try self.indent();
                    // Read the actual statement pointer from the extra buffer
                    try self.printStatement(self.parser.extra.items[i]);
                    self.writer.writeAll("\n") catch return error.InternalError;
                }
                self.indent_level -= 1;
                try self.indent();
                self.writer.writeAll("}") catch return error.InternalError;
            },
            .InlineAssembly => |token_ptr| {
                self.writer.print("asm \"{s}\";", .{self.getTokenLexeme(token_ptr)}) catch return error.InternalError;
            },
            .FunctionDefinition => |start| {
                const is_public = self.parser.extra.items[start] == 1;
                const name_idx = self.parser.extra.items[start + 1];
                const params_start = self.parser.extra.items[start + 2];
                const params_end = self.parser.extra.items[start + 3];
                const returns_start = self.parser.extra.items[start + 4];
                const returns_end = self.parser.extra.items[start + 5];
                const body_ptr = self.parser.extra.items[start + 6];

                if (is_public) self.writer.writeAll("pub ") catch return error.InternalError;
                self.writer.print("fn {s}(", .{self.getTokenLexeme(name_idx)}) catch return error.InternalError;
                
                for (params_start..params_end, 0..) |i, count| {
                    if (count > 0) self.writer.writeAll(", ") catch return error.InternalError;
                    try self.printVariableSignature(self.parser.extra.items[i]);
                }
                self.writer.writeAll(") -> ") catch return error.InternalError;
                
                for (returns_start..returns_end, 0..) |i, count| {
                    if (count > 0) self.writer.writeAll(", ") catch return error.InternalError;
                    try self.printExpression(self.parser.extra.items[i]);
                }
                self.writer.writeAll(" ") catch return error.InternalError;
                try self.printStatement(body_ptr);
            },
            .Return => |expr_ptr| {
                self.writer.writeAll("return ") catch return error.InternalError;
                try self.printExpression(expr_ptr);
                self.writer.writeAll(";") catch return error.InternalError;
            },
            .Conditional => |start| {
                const condition = self.parser.extra.items[start];
                const body = self.parser.extra.items[start + 1];
                const has_otherwise = self.parser.extra.items[start + 2] == 1;

                self.writer.writeAll("if ") catch return error.InternalError;
                try self.printExpression(condition);
                self.writer.writeAll(" ") catch return error.InternalError;
                try self.printStatement(body);
                
                if (has_otherwise) {
                    const otherwise = self.parser.extra.items[start + 3];
                    self.writer.writeAll(" else ") catch return error.InternalError;
                    try self.printStatement(otherwise);
                }
            },
            .While => |start| {
                const condition = self.parser.extra.items[start];
                const body = self.parser.extra.items[start + 1];

                self.writer.writeAll("while ") catch return error.InternalError;
                try self.printExpression(condition);
                self.writer.writeAll(" ") catch return error.InternalError;
                try self.printStatement(body);
            },
            .Break => self.writer.writeAll("break;") catch return error.InternalError,
            .Continue => self.writer.writeAll("continue;") catch return error.InternalError,
            .VariableDefinition => |start| {
                const sig_start = self.parser.extra.items[start];
                const sig_end = self.parser.extra.items[start + 1];
                const expr_ptr = self.parser.extra.items[start + 2];

                if (sig_start < sig_end) {
                    const first_sig = self.parser.signaturePool.get(self.parser.extra.items[sig_start]);
                    if (first_sig.public) self.writer.writeAll("pub ") catch return error.InternalError;
                }
                
                self.writer.writeAll("let ") catch return error.InternalError;
                for (sig_start..sig_end, 0..) |i, count| {
                    if (count > 0) self.writer.writeAll(", ") catch return error.InternalError;
                    try self.printVariableSignature(self.parser.extra.items[i]);
                }
                
                self.writer.writeAll(" = ") catch return error.InternalError;
                try self.printExpression(expr_ptr);
                self.writer.writeAll(";") catch return error.InternalError;
            },
            .Discard => |expr_ptr| {
                self.writer.writeAll("_ = ") catch return error.InternalError;
                try self.printExpression(expr_ptr);
                self.writer.writeAll(";") catch return error.InternalError;
            },
            .Namespace => |expr_ptr| {
                self.writer.writeAll("namespace ") catch return error.InternalError;
                try self.printExpression(expr_ptr);
                self.writer.writeAll(";") catch return error.InternalError;
            },
            .Include => |token_ptr| {
                self.writer.print("include \"{s}\";", .{self.getTokenLexeme(token_ptr)}) catch return error.InternalError;
            },
        }
    }

    pub fn printExpression(self: *Self, ptr: u32) common.CompilerError!void {
        const expr = self.parser.expressionMap.get(ptr);
        switch (expr) {
            .Binary => |start| {
                const lhs = self.parser.extra.items[start];
                const op = @as(TokenType, @enumFromInt(self.parser.extra.items[start + 1]));
                const rhs = self.parser.extra.items[start + 2];
                
                try self.printExpression(lhs);
                self.writer.print(" {s} ", .{operatorToString(op)}) catch return error.InternalError;
                try self.printExpression(rhs);
            },
            .Grouping => |inner| {
                self.writer.writeAll("(") catch return error.InternalError;
                try self.printExpression(inner);
                self.writer.writeAll(")") catch return error.InternalError;
            },
            .Literal, .Identifier => |token_ptr| {
                self.writer.writeAll(self.getTokenLexeme(token_ptr)) catch return error.InternalError;
            },
            .Unary => |start| {
                const op = @as(TokenType, @enumFromInt(self.parser.extra.items[start]));
                const rhs = self.parser.extra.items[start + 1];
                self.writer.print("{s}", .{operatorToString(op)}) catch return error.InternalError;
                try self.printExpression(rhs);
            },
            .Call => |start| {
                const callee = self.parser.extra.items[start];
                const args_start = self.parser.extra.items[start + 1];
                const args_end = self.parser.extra.items[start + 2];

                try self.printExpression(callee);
                self.writer.writeAll("(") catch return error.InternalError;
                for (args_start..args_end, 0..) |i, count| {
                    if (count > 0) self.writer.writeAll(", ") catch return error.InternalError;
                    try self.printExpression(self.parser.extra.items[i]);
                }
                self.writer.writeAll(")") catch return error.InternalError;
            },
            .Conditional => |start| {
                const condition = self.parser.extra.items[start];
                const then_branch = self.parser.extra.items[start + 1];
                const otherwise = self.parser.extra.items[start + 2];

                self.writer.writeAll("if ") catch return error.InternalError;
                try self.printExpression(condition);
                self.writer.writeAll(" ") catch return error.InternalError;
                try self.printExpression(then_branch);
                self.writer.writeAll(" else ") catch return error.InternalError;
                try self.printExpression(otherwise);
            },
            .Scoping => |start| {
                const lhs = self.parser.extra.items[start];
                const rhs_token = self.parser.extra.items[start + 1];
                
                try self.printExpression(lhs);
                self.writer.print("::{s}", .{self.getTokenLexeme(rhs_token)}) catch return error.InternalError;
            },
            .Dot => |start| {
                const lhs = self.parser.extra.items[start];
                const rhs_token = self.parser.extra.items[start + 1];
                
                try self.printExpression(lhs);
                self.writer.print(".{s}", .{self.getTokenLexeme(rhs_token)}) catch return error.InternalError;
            },
            .Indexing => |start| {
                const target = self.parser.extra.items[start];
                const index = self.parser.extra.items[start + 1];
                
                try self.printExpression(target);
                self.writer.writeAll("[") catch return error.InternalError;
                try self.printExpression(index);
                self.writer.writeAll("]") catch return error.InternalError;
            },
            .ExpressionList => |range| {
                self.writer.writeAll("{") catch return error.InternalError;
                for (range.start..range.end, 0..) |i, count| {
                    if (count > 0) self.writer.writeAll(", ") catch return error.InternalError;
                    try self.printExpression(self.parser.extra.items[i]);
                }
                self.writer.writeAll("}") catch return error.InternalError;
            },
            .Type => |type_val| {
                switch (type_val) {
                    .Pointer => |inner| {
                        self.writer.writeAll("*") catch return error.InternalError;
                        try self.printExpression(inner);
                    },
                    .Slice => |inner| {
                        self.writer.writeAll("[]") catch return error.InternalError;
                        try self.printExpression(inner);
                    },
                    .Mutable => |inner| {
                        self.writer.writeAll("mut ") catch return error.InternalError;
                        try self.printExpression(inner);
                    },
                    .Function => |start| {
                        const params_start = self.parser.extra.items[start];
                        const params_end = self.parser.extra.items[start + 1];
                        const returns_start = self.parser.extra.items[start + 2];
                        const returns_end = self.parser.extra.items[start + 3];

                        self.writer.writeAll("fn(") catch return error.InternalError;
                        for (params_start..params_end, 0..) |i, count| {
                            if (count > 0) self.writer.writeAll(", ") catch return error.InternalError;
                            try self.printExpression(self.parser.extra.items[i]);
                        }
                        self.writer.writeAll(") -> ") catch return error.InternalError;
                        for (returns_start..returns_end, 0..) |i, count| {
                            if (count > 0) self.writer.writeAll(", ") catch return error.InternalError;
                            try self.printExpression(self.parser.extra.items[i]);
                        }
                    },
                    .Value => |start| {
                        const token_idx = self.parser.extra.items[start + 1];
                        self.writer.writeAll(self.getTokenLexeme(token_idx)) catch return error.InternalError;
                    },
                }
            },
            .LayoutDefinition => |start| {
                const vars_start = self.parser.extra.items[start];
                const vars_end = self.parser.extra.items[start + 1];
                const fns_start = self.parser.extra.items[start + 2];
                const fns_end = self.parser.extra.items[start + 3];

                self.writer.writeAll("layout {\n") catch return error.InternalError;
                self.indent_level += 1;
                
                for (vars_start..vars_end) |var_idx| {
                    try self.indent();
                    try self.printVariableSignature(self.parser.extra.items[var_idx]); 
                    self.writer.writeAll(",\n") catch return error.InternalError;
                }
                for (fns_start..fns_end) |fn_idx| {
                    try self.indent();
                    try self.printStatement(self.parser.extra.items[fn_idx]);
                    self.writer.writeAll("\n") catch return error.InternalError;
                }
                
                self.indent_level -= 1;
                try self.indent();
                self.writer.writeAll("}") catch return error.InternalError;
            },
        }
    }

    fn printVariableSignature(self: *Self, ptr: u32) common.CompilerError!void {
        const sig = self.parser.signaturePool.get(ptr);
        
        if (sig.public) self.writer.writeAll("pub ") catch return error.InternalError;
        self.writer.writeAll(self.getTokenLexeme(sig.name)) catch return error.InternalError;
        
        const type_expr = self.parser.expressionMap.get(sig.type);
        var is_inferred = false;
        if (type_expr == .Type and type_expr.Type == .Value) {
            const start = type_expr.Type.Value;
            const has_type = self.parser.extra.items[start] == 1; 
            if (!has_type) is_inferred = true;
        }

        if (!is_inferred) {
            self.writer.writeAll(": ") catch return error.InternalError;
            try self.printExpression(sig.type);
        }
    }

    fn getTokenLexeme(self: *Self, token_index: u32) []const u8 {
        return self.parser.tokens[token_index].lexeme(self.parser.file);
    }
    
    fn operatorToString(token_type: TokenType) []const u8 {
        return switch (token_type) {
            .Plus => "+",
            .Minus => "-",
            .Star => "*",
            .Slash => "/",
            .Equal => "=",
            .EqualEqual => "==",
            .BangEqual => "!=",
            .Lesser => "<",
            .LesserEqual => "<=",
            .Greater => ">",
            .GreaterEqual => ">=",
            .Pipe => "|",
            .Ampersand => "&",
            .Xor => "^",
            .LeftShift => "<<",
            .RightShift => ">>",
            .Bang => "!",
            .Tilde => "~",
            .And => "and",
            .Or => "or",
            else => @tagName(token_type), 
        };
    }
};
