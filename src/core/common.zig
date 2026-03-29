const common = @This();

const std = @import("std");
const builtin = @import("builtin");
const lexer = @import("../lexer/lexer.zig");
const parser = @import("../parser/parser.zig");
const defines = @import("defines.zig");

pub const log = @import("log.zig");
pub const CompilerContext = @import("context.zig");
pub const CompilerSettings = @import("settings.zig");

pub const JASL_VERSION = "0.0.1";

pub const CompilerError = error {
    MissingFlag,
    UnknownFlag,
    InternalError,
    NoSourceFile,
    IOError,
    InvalidToken,
    UnterminatedComment,
    UnterminatedStringLiteral,
    DotPrefixedNumericLiteral,
    DotPostfixedNumericLiteral,
    UnexpectedCharacter,
    AllocatorFailure,
    MissingBrace,
    MissingParenthesis,
    MissingSemicolon,
    MissingComma,
    MissingArrow,
    MissingTypeSpecifier,
    MissingIdentifier,
    MissingColon,
    MissingAssignment,
    MissingBracket,
    MissingBranch,
    MissingStatement,
    MultipleErrors,
    ThreadingError,
    Unimplemented,
    IllegalSyntax,
    PathNameTooLong,
    OutOfMemory,
    EmptyCharLiteral,
    FileNotFound,
};
