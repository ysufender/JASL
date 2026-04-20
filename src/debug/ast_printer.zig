const std = @import("std");
const common = @import("../core/common.zig");
const defines = @import("../core/defines.zig");
const parser = @import("../parser/parser.zig");

const AST = parser.AST;
const Expression = parser.Expression;
const Statement = parser.Statement;

const Error = common.CompilerError;

pub fn printAST(ast: *const AST, context: *common.CompilerContext) void {
    var ctx = PrintContext{
        .ast = ast,
        .tokens = context.getTokens(ast.tokens),
        .context = context,
        .file = ast.tokens,
    };
    for (ast.statementMask) |si| {
        ctx.printStmt(@intCast(si), 0);
    }
}

const PrintContext = struct {
    ast: *const AST,
    tokens: *const @TypeOf(@as(*common.CompilerContext, undefined).getTokens(0).*),
    context: *common.CompilerContext,
    file: defines.FilePtr,

    fn write(_: *PrintContext, bytes: []const u8) void {
        common.log.print("{s}", .{bytes});
    }

    fn print(_: *PrintContext, comptime fmt: []const u8, args: anytype) void {
        common.log.print(fmt, args);
    }

    fn indent(self: *PrintContext, depth: u32) void {
        var i: u32 = 0;
        while (i < depth) : (i += 1) {
            self.write(" ");
        }
    }

    fn tokenLexeme(self: *PrintContext, ptr: defines.TokenPtr) []const u8 {
        return self.tokens.get(ptr).lexeme(self.context, self.file);
    }

    fn printStmt(self: *PrintContext, si: defines.StatementPtr, depth: u32) void {
        const stmts = self.ast.statements;
        const stype = stmts.items(.type)[si];
        const val   = stmts.items(.value)[si];
        const ex    = self.ast.extra;

        self.indent(depth);

        switch (stype) {
            .Block => {
                self.write("Block {\n");
                const start = ex[val];
                const end   = ex[val + 1];
                for (ex[start..end]) |child| {
                    self.printStmt(@intCast(child), depth + 1);
                }
                self.indent(depth);
                self.write("}\n");
            },

            .Return => {
                self.write("Return\n");
                self.printExpr(@intCast(val), depth + 1);
            },

            .Discard => {
                self.write("Discard\n");
                self.printExpr(@intCast(val), depth + 1);
            },

            .Expression => {
                self.write("ExprStmt\n");
                self.printExpr(@intCast(val), depth + 1);
            },

            .Defer => {
                self.write("Defer\n");
                self.printExpr(@intCast(val), depth + 1);
            },

            .VariableDefinition => {
                const sig_start = ex[val];
                const sig_end   = ex[val + 1];
                const expr_idx  = ex[val + 2];
                const is_pub = sig_end > sig_start and
                    self.ast.signatures.items(.public)[ex[sig_start]];
                self.print("Let{s}\n", .{if (is_pub) " pub" else ""});
                for (ex[sig_start..sig_end]) |raw_sig| {
                    self.printSig(@intCast(raw_sig), depth + 1);
                }
                self.indent(depth + 1);
                self.write("=\n");
                self.printExpr(@intCast(expr_idx), depth + 2);
            },

            .Conditional => {
                const cond     = ex[val];
                const body     = ex[val + 1];
                const has_else = ex[val + 2];
                self.write("If\n");
                self.indent(depth + 1);
                self.write("cond:\n");
                self.printExpr(@intCast(cond), depth + 2);
                self.indent(depth + 1);
                self.write("then:\n");
                self.printStmt(@intCast(body), depth + 2);
                if (has_else != 0) {
                    self.indent(depth + 1);
                    self.write("else:\n");
                    self.printStmt(@intCast(ex[val + 3]), depth + 2);
                }
            },

            .While => {
                self.write("While\n");
                self.indent(depth + 1);
                self.write("cond:\n");
                self.printExpr(@intCast(ex[val]), depth + 2);
                self.indent(depth + 1);
                self.write("body:\n");
                self.printStmt(@intCast(ex[val + 1]), depth + 2);
            },

            .Switch => {
                self.write("Switch\n");
                self.indent(depth + 1);
                self.write("subject:\n");
                self.printExpr(@intCast(ex[val]), depth + 2);
                self.printCases(ex, ex[val + 1], ex[val + 2], depth, true);
            },

            .Break    => self.write("Break\n"),
            .Continue => self.write("Continue\n"),

            .Import => {
                const module    = ex[val];
                const has_alias = ex[val + 1];
                self.write("Import\n");
                self.printExpr(@intCast(module), depth + 1);
                if (has_alias != 0) {
                    self.indent(depth + 1);
                    self.print("as {s}\n", .{self.tokenLexeme(@intCast(ex[val + 2]))});
                }
            },

            .InlineAssembly => {
                self.print("Asm {s}\n", .{self.tokenLexeme(val)});
            },

            .Mark => {
                self.write("Mark(\n");
                for (ex[ex[val]..ex[val + 1]]) |hint| {
                    self.printExpr(@intCast(hint), depth + 1);
                }
                self.indent(depth);
                self.write(")\n");
                self.printStmt(@intCast(ex[val + 2]), depth);
            },
        }
    }

    fn printExpr(self: *PrintContext, ei: defines.ExpressionPtr, depth: u32) void {
        const exprs = self.ast.expressions;
        const etype = exprs.items(.type)[ei];
        const val   = exprs.items(.value)[ei];
        const ex    = self.ast.extra;

        self.indent(depth);
        switch (etype) {
            .Literal => {
                self.print("Literal({s})\n", .{self.tokenLexeme(val)});
            },

            .Identifier => {
                self.print("Ident({s})\n", .{self.tokenLexeme(val)});
            },

            .Binary => {
                self.print("Binary({s})\n", .{opSymbol(@intCast(ex[val + 1]))});
                self.printExpr(@intCast(ex[val]),     depth + 1);
                self.printExpr(@intCast(ex[val + 2]), depth + 1);
            },

            .Unary => {
                self.print("Unary({s})\n", .{opSymbol(@intCast(ex[val]))});
                self.printExpr(@intCast(ex[val + 1]), depth + 1);
            },

            .Assignment => {
                self.write("Assign\n");
                self.printExpr(@intCast(ex[val]),     depth + 1);
                self.printExpr(@intCast(ex[val + 1]), depth + 1);
            },

            .Call => {
                self.write("Call\n");
                self.indent(depth + 1);
                self.write("callee:\n");
                self.printExpr(@intCast(ex[val]), depth + 2);
                self.indent(depth + 1);
                self.write("args:\n");
                self.printExpr(@intCast(ex[val + 1]), depth + 2);
            },

            .ExpressionList => {
                self.write("List\n");
                for (ex[ex[val]..ex[val + 1]]) |child| {
                    self.printExpr(@intCast(child), depth + 1);
                }
            },

            .Dot => {
                self.print("Dot(.{s})\n", .{self.tokenLexeme(@intCast(ex[val + 1]))});
                self.printExpr(@intCast(ex[val]), depth + 1);
            },

            .Scoping => {
                self.print("Scope(::{s})\n", .{self.tokenLexeme(@intCast(ex[val + 1]))});
                self.printExpr(@intCast(ex[val]), depth + 1);
            },

            .Indexing => {
                self.write("Index\n");
                self.printExpr(@intCast(ex[val]), depth + 1);
                self.indent(depth + 1);
                self.write("at:\n");
                self.printExpr(@intCast(ex[val + 1]), depth + 2);
            },

            .Slicing => {
                self.write("Slice\n");
                self.printExpr(@intCast(ex[val]), depth + 1);
                self.indent(depth + 1);
                self.write("from:\n");
                self.printExpr(@intCast(ex[val + 1]), depth + 2);
                self.indent(depth + 1);
                self.write("to:\n");
                self.printExpr(@intCast(ex[val + 2]), depth + 2);
            },

            .Cast => {
                self.write("Cast\n");
                self.printExpr(@intCast(ex[val]), depth + 1);
                self.indent(depth + 1);
                self.write("to:\n");
                self.printExpr(@intCast(ex[val + 1]), depth + 2);
            },

            .Conditional => {
                self.write("IfExpr\n");
                self.indent(depth + 1);
                self.write("cond:\n");
                self.printExpr(@intCast(ex[val]),     depth + 2);
                self.indent(depth + 1);
                self.write("then:\n");
                self.printExpr(@intCast(ex[val + 1]), depth + 2);
                self.indent(depth + 1);
                self.write("else:\n");
                self.printExpr(@intCast(ex[val + 2]), depth + 2);
            },

            .Switch => {
                self.write("SwitchExpr\n");
                self.indent(depth + 1);
                self.write("subject:\n");
                self.printExpr(@intCast(ex[val]), depth + 2);
                self.printCases(ex, ex[val + 1], ex[val + 2], depth, false);
            },

            .FunctionDefinition => {
                const param_start = ex[val];
                const param_end   = ex[val + 1];
                const ret         = ex[val + 2];
                const body        = ex[val + 3];
                self.write("FnDef\n");
                for (ex[param_start..param_end]) |raw_sig| {
                    self.indent(depth + 1);
                    self.write("param:\n");
                    self.printSig(@intCast(raw_sig), depth + 2);
                }
                self.indent(depth + 1);
                self.write("returns:\n");
                self.printExpr(@intCast(ret), depth + 2);
                self.indent(depth + 1);
                self.write("body:\n");
                self.printStmt(@intCast(body), depth + 2);
            },

            .Lambda => {
                const capture_start = ex[val];
                const capture_end   = ex[val + 1];
                const body          = ex[val + 2];
                self.write("Lambda\n");
                for (ex[capture_start..capture_end]) |tok| {
                    self.indent(depth + 1);
                    self.print("capture: {s}\n", .{self.tokenLexeme(@intCast(tok))});
                }
                self.indent(depth + 1);
                self.write("body:\n");
                self.printExpr(@intCast(body), depth + 2);
            },

            .StructDefinition => {
                const field_start = ex[val];
                const field_end   = ex[val + 1];
                const def_start   = ex[val + 2];
                const def_end     = ex[val + 3];
                self.write("Struct {\n");
                for (ex[field_start..field_end]) |raw_sig| {
                    self.printSig(@intCast(raw_sig), depth + 1);
                }
                for (ex[def_start..def_end]) |raw_stmt| {
                    self.printStmt(@intCast(raw_stmt), depth + 1);
                }
                self.indent(depth);
                self.write("}\n");
            },

            .EnumDefinition => {
                const var_start = ex[val];
                const var_end   = ex[val + 1];
                const def_start = ex[val + 2];
                const def_end   = ex[val + 3];
                self.write("Enum {\n");
                for (ex[var_start..var_end]) |tok| {
                    self.indent(depth + 1);
                    self.print("{s},\n", .{self.tokenLexeme(@intCast(tok))});
                }
                for (ex[def_start..def_end]) |raw_stmt| {
                    self.printStmt(@intCast(raw_stmt), depth + 1);
                }
                self.indent(depth);
                self.write("}\n");
            },

            .UnionDefinition => {
                const tagged = ex[val];
                var off: usize = val + 1;
                if (tagged != 0) {
                    const has_tag = ex[off];
                    off += 1;
                    if (has_tag != 0) {
                        self.write("Union(");
                        self.printExpr(@intCast(ex[off]), 0);
                        off += 1;
                        self.indent(depth);
                        self.write(") {\n");
                    } else {
                        self.write("Union(enum) {\n");
                    }
                } else {
                    self.write("Union {\n");
                }
                const var_start = ex[off];
                const var_end   = ex[off + 1];
                const def_start = ex[off + 2];
                const def_end   = ex[off + 3];
                for (ex[var_start..var_end]) |raw_sig| {
                    self.printSig(@intCast(raw_sig), depth + 1);
                }
                for (ex[def_start..def_end]) |raw_stmt| {
                    self.printStmt(@intCast(raw_stmt), depth + 1);
                }
                self.indent(depth);
                self.write("}\n");
            },

            .PointerType  => { self.write("*");     self.printExpr(val, depth); },
            .CPointerType => { self.write("[@c]");  self.printExpr(val, depth); },
            .SliceType    => { self.write("[]");    self.printExpr(val, depth); },
            .MutableType  => { self.write("mut ");  self.printExpr(val, depth); },

            .ArrayType => {
                const size_ei = ex[val];
                const size_et = self.ast.expressions.items(.type)[size_ei];
                const size_ev = self.ast.expressions.items(.value)[size_ei];
                self.write("[");
                if (size_et == .Literal or size_et == .Identifier) {
                    self.print("{s}", .{self.tokenLexeme(size_ev)});
                } else {
                    self.print("#{d}", .{size_ei});
                }
                self.write("]");
                self.printExpr(@intCast(ex[val + 1]), depth);
            },

            .FunctionType => {
                self.write("fn ");
                self.printExpr(@intCast(ex[val]),     depth);
                self.indent(depth);
                self.write("-> ");
                self.printExpr(@intCast(ex[val + 1]), depth);
            },

            .Mark => {
                self.write("Mark(\n");
                for (ex[ex[val]..ex[val + 1]]) |hint| {
                    self.printExpr(@intCast(hint), depth + 1);
                }
                self.indent(depth);
                self.write(")\n");
                self.printExpr(@intCast(ex[val + 2]), depth);
            },
        }
    }

    fn printSig(self: *PrintContext, si: defines.OpaquePtr, depth: u32) void {
        const sigs = self.ast.signatures;
        const sig  = sigs.get(si);
        self.indent(depth);
        if (sig.public) self.write("pub ");
        self.print("{s}", .{self.tokenLexeme(sig.name)});
        if (sig.type != 0) {
            self.write(": ");
            self.printExpr(sig.type, 0);
        } else {
            self.write("\n");
        }
    }

    fn printCases(
        self: *PrintContext,
        ex: []const defines.OpaquePtr,
        case_start: defines.OpaquePtr,
        case_end: defines.OpaquePtr,
        depth: u32,
        comptime is_stmt: bool,
    ) void {
        var i: usize = case_start;
        while (i < case_end) : (i += 3) {
            const case_expr = ex[i];
            const capture   = ex[i + 1];
            const case_body = ex[i + 2];
            self.indent(depth + 1);
            if (case_expr == 0) {
                self.write("else");
            } else {
                self.write("case:\n");
                self.printExpr(@intCast(case_expr), depth + 2);
                self.indent(depth + 1);
            }
            if (capture != 0) {
                self.print(" |{s}|", .{self.tokenLexeme(@intCast(capture))});
            }
            self.write(" ->\n");
            if (is_stmt) {
                self.printStmt(@intCast(case_body), depth + 2);
            } else {
                self.printExpr(@intCast(case_body), depth + 2);
            }
        }
    }
};

fn opSymbol(op: u32) []const u8 {
    return switch (op) {
        0  => "==",
        1  => "!=",
        2  => "<",
        3  => "<=",
        4  => ">",
        5  => ">=",
        6  => "+",
        7  => "-",
        8  => "*",
        9  => "/",
        10 => "&&",
        11 => "||",
        12 => "&",
        13 => "|",
        14 => "^",
        15 => "<<",
        16 => ">>",
        17 => "!",
        18 => "-",
        19 => "~",
        else => "?op",
    };
}
