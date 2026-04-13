const std = @import("std"); 
const common = @import("common.zig");
const builtin = @import("builtin");

const Settings = common.CompilerSettings;

pub const FilePtr = u32;
pub const TokenListPtr = u32;
pub const ASTPtr = u32;
pub const OpaquePtr = u32;
pub const Offset = u32;

pub const Range = struct {
    start: u32,
    end: u32,
};

pub const ExpressionPtr = u32;
pub const StatementPtr = u32;
pub const TokenPtr = u32;
pub const SignaturePtr = u32;

pub const SymbolPtr = u32;
pub const ModulePtr = u32;

pub const ScopePtr = u32;
pub const DeclPtr = u32;

pub const TypePtr = u32;

pub const rehashLimit = 512;
