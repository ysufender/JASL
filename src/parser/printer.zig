const std = @import("std");
const lexer = @import("../lexer/lexer.zig");
const parser = @import("parser.zig");

pub const AstPrinter = struct {
    indentLevel: usize = 0,

    pub fn printAst(writer: anytype, list: parser.StatementList) !void {
        var self = AstPrinter{
            .indentLevel = 0,
        };

        for (list.items) |stmt| {
            try self.printStatement(writer, stmt);
            try writer.writeAll("\n");
        }
    }

    fn indent(self: *AstPrinter, writer: anytype) !void {
        var i: usize = 0;
        while (i < self.indentLevel) : (i += 1) {
            try writer.writeAll("  ");
        }
    }

    pub fn printStatement(self: *AstPrinter, writer: anytype, stmt: *const parser.Statement) anyerror!void {
        try self.indent(writer);
        switch (stmt.*) {
            .Block => |statements| {
                try writer.writeAll("Block:\n");
                self.indentLevel += 1;
                for (statements.items) |s| {
                    try self.printStatement(writer, s);
                }
                self.indentLevel -= 1;
            },
            .InlineAssembly => |asm_str| {
                try writer.print("InlineAssembly: {s}\n", .{asm_str});
            },
            .FunctionDefinition => |f| {
                try writer.print("FunctionDefinition: '{s}' (pub: {any})\n", .{ f.name.lexeme, f.public });
                self.indentLevel += 1;

                try self.indent(writer);
                try writer.writeAll("Params:\n");
                self.indentLevel += 1;
                for (f.params.items) |p| {
                    try self.printVariableSignature(writer, p);
                }
                self.indentLevel -= 1;

                try self.indent(writer);
                try writer.writeAll("Returns:\n");
                self.indentLevel += 1;
                for (f.returnType.items) |r| {
                    try self.printExpression(writer, r);
                }
                self.indentLevel -= 1;

                try self.indent(writer);
                try writer.writeAll("Body:\n");
                self.indentLevel += 1;
                try self.printStatement(writer, f.body);
                self.indentLevel -= 1;

                self.indentLevel -= 1;
            },
            .Return => |expr| {
                try writer.writeAll("Return:\n");
                self.indentLevel += 1;
                try self.printExpression(writer, expr);
                self.indentLevel -= 1;
            },
            .Conditional => |c| {
                try writer.writeAll("If:\n");
                self.indentLevel += 1;
                try self.printExpression(writer, c.condition);
                self.indentLevel -= 1;

                try self.indent(writer);
                try writer.writeAll("Then:\n");
                self.indentLevel += 1;
                try self.printStatement(writer, c.body);
                self.indentLevel -= 1;

                if (c.otherwise) |otherwise| {
                    try self.indent(writer);
                    try writer.writeAll("Else:\n");
                    self.indentLevel += 1;
                    try self.printStatement(writer, otherwise);
                    self.indentLevel -= 1;
                }
            },
            .While => |w| {
                try writer.writeAll("While:\n");
                self.indentLevel += 1;
                try self.printExpression(writer, w.condition);
                try self.printStatement(writer, w.body);
                self.indentLevel -= 1;
            },
            .Break => {
                try writer.writeAll("Break\n");
            },
            .Continue => {
                try writer.writeAll("Continue\n");
            },
            .VariableDefinition => |v| {
                try writer.writeAll("VariableDefinition:\n");
                self.indentLevel += 1;
                
                try self.indent(writer);
                try writer.writeAll("Signatures:\n");
                self.indentLevel += 1;
                for (v.signatures.items) |sig| {
                    try self.printVariableSignature(writer, sig);
                }
                self.indentLevel -= 1;
                
                try self.indent(writer);
                try writer.writeAll("Initializer:\n");
                self.indentLevel += 1;
                try self.printExpression(writer, v.initializer);
                self.indentLevel -= 1;
                
                self.indentLevel -= 1;
            },
            .Discard => |expr| {
                try writer.writeAll("Discard:\n");
                self.indentLevel += 1;
                try self.printExpression(writer, expr);
                self.indentLevel -= 1;
            },
            .Namespace => |expr| {
                try writer.writeAll("Namespace:\n");
                self.indentLevel += 1;
                try self.printExpression(writer, expr);
                self.indentLevel -= 1;
            },
            .Include => |token| {
                try writer.print("Include: '{s}'\n", .{token.lexeme});
            },
        }
    }

    pub fn printExpression(self: *AstPrinter, writer: anytype, expr: *const parser.Expression) anyerror!void {
        try self.indent(writer);
        switch (expr.*) {
            .Binary => |b| {
                try writer.print("Binary (Operator: {s})\n", .{@tagName(b.operator)});
                self.indentLevel += 1;
                try self.printExpression(writer, b.lhs);
                try self.printExpression(writer, b.rhs);
                self.indentLevel -= 1;
            },
            .Grouping => |g| {
                try writer.writeAll("Grouping:\n");
                self.indentLevel += 1;
                try self.printExpression(writer, g);
                self.indentLevel -= 1;
            },
            .Literal => |l| {
                try writer.print("Literal: '{s}'\n", .{l.lexeme});
            },
            .Identifier => |i| {
                try writer.print("Identifier: '{s}'\n", .{i.lexeme});
            },
            .Unary => |u| {
                try writer.print("Unary (Operator: {s})\n", .{@tagName(u.operator)});
                self.indentLevel += 1;
                try self.printExpression(writer, u.rhs);
                self.indentLevel -= 1;
            },
            .LayoutDefinition => |l| {
                try writer.writeAll("LayoutDefinition:\n");
                self.indentLevel += 1;
                for (l.variables.items) |sig| {
                    try self.printVariableSignature(writer, sig);
                }
                for (l.functions.items) |function| {
                    try self.printStatement(writer, function);
                }
                self.indentLevel -= 1;
            },
            .Call => |c| {
                try writer.writeAll("Call:\n");
                self.indentLevel += 1;
                
                try self.indent(writer);
                try writer.writeAll("Function:\n");
                self.indentLevel += 1;
                try self.printExpression(writer, c.function);
                self.indentLevel -= 1;

                try self.indent(writer);
                try writer.writeAll("Arguments:\n");
                self.indentLevel += 1;
                for (c.arguments.items) |arg| {
                    try self.printExpression(writer, arg);
                }
                self.indentLevel -= 1;
                
                self.indentLevel -= 1;
            },
            .Conditional => |c| {
                try writer.writeAll("ConditionalExpr:\n");
                self.indentLevel += 1;
                
                try self.printExpression(writer, c.condition);
                
                try self.indent(writer);
                try writer.writeAll("Then:\n");
                self.indentLevel += 1;
                try self.printExpression(writer, c.then);
                self.indentLevel -= 1;
                
                try self.indent(writer);
                try writer.writeAll("Otherwise:\n");
                self.indentLevel += 1;
                try self.printExpression(writer, c.otherwise);
                self.indentLevel -= 1;
                
                self.indentLevel -= 1;
            },
            .Type => |t| {
                try writer.print("Type (mutable: {any}):\n", .{t.mutable});
                self.indentLevel += 1;
                try self.indent(writer);
                switch (t.type) {
                    .Pointer => |p| {
                        try writer.writeAll("Pointer:\n");
                        self.indentLevel += 1;
                        try self.printExpression(writer, p);
                        self.indentLevel -= 1;
                    },
                    .Slice => |s| {
                        try writer.writeAll("Slice:\n");
                        self.indentLevel += 1;
                        try self.printExpression(writer, s);
                        self.indentLevel -= 1;
                    },
                    .Function => |f| {
                        try writer.writeAll("FunctionSignature:\n");
                        self.indentLevel += 1;
                        
                        try self.indent(writer);
                        try writer.writeAll("Params:\n");
                        self.indentLevel += 1;
                        for (f.parameters.items) |p| {
                            try self.printExpression(writer, p);
                        }
                        self.indentLevel -= 1;
                        
                        try self.indent(writer);
                        try writer.writeAll("Returns:\n");
                        self.indentLevel += 1;
                        for (f.returns.items) |r| {
                            try self.printExpression(writer, r);
                        }
                        self.indentLevel -= 1;
                        self.indentLevel -= 1;
                    },
                    .Value => |v| {
                        try writer.print("Value: '{s}'\n", .{v.lexeme});
                    },
                }
                self.indentLevel -= 1;
            },
            .Scoping => |s| {
                try writer.print("Scoping (Member: '{s}'):\n", .{s.member.lexeme});
                self.indentLevel += 1;
                try self.printExpression(writer, s.namespace);
                self.indentLevel -= 1;
            },
            .ExpressionList => |el| {
                try writer.writeAll("ExpressionList:\n");
                self.indentLevel += 1;
                for (el.items) |e| {
                    try self.printExpression(writer, e);
                }
                self.indentLevel -= 1;
            },
            .Dot => |d| {
                try writer.print("Dot (RHS: '{s}'):\n", .{d.rhs.lexeme});
                self.indentLevel += 1;
                try self.printExpression(writer, d.lhs);
                self.indentLevel -= 1;
            },
            .Indexing => |i| {
                try writer.writeAll("Indexing:\n");
                self.indentLevel += 1;
                
                try self.indent(writer);
                try writer.writeAll("LHS:\n");
                self.indentLevel += 1;
                try self.printExpression(writer, i.lhs);
                self.indentLevel -= 1;
                
                try self.indent(writer);
                try writer.writeAll("Index:\n");
                self.indentLevel += 1;
                try self.printExpression(writer, i.index);
                self.indentLevel -= 1;
                
                self.indentLevel -= 1;
            },
        }
    }

    pub fn printVariableSignature(self: *AstPrinter, writer: anytype, sig: parser.VariableSignature) anyerror!void {
        try self.indent(writer);
        try writer.print("Signature: '{s}' (pub: {any})\n", .{ sig.name.lexeme, sig.public });
        self.indentLevel += 1;
        try self.printExpression(writer, sig.type);
        self.indentLevel -= 1;
    }
};
