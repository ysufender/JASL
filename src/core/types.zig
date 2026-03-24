const std = @import("std"); 
const common = @import("common.zig");

//pub const Lock = std.Thread.Mutex;
pub const Lock =
    if (common.CompilerSettings.threading) std.Thread.RwLock
    else struct {
        pub fn lock(_: *Lock) void {}
        pub fn unlock(_: *Lock) void {}

        pub fn lockShared(_: *Lock) void {}
        pub fn unlockShared(_: *Lock) void {}
    };

pub const ThreadPool =
    if (common.CompilerSettings.threading) std.Thread.Pool
    else struct {
        pub fn init(_: *ThreadPool, _: anytype) common.CompilerError!void { }
        pub fn spawnWg(_: *ThreadPool, _: *WaitGroup, function: anytype, args: anytype) void {
            _ = @call(.always_inline, function, args);
        }
    };

pub const WaitGroup =
    if (common.CompilerSettings.threading) std.Thread.WaitGroup
    else struct {
        pub fn wait(_: *WaitGroup) void {}
    };

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
