const std = @import("std"); 
const common = @import("common.zig");
const builtin = @import("builtin");

pub const Debug = builtin.mode == .Debug;

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

pub const rehashLimit = 512;

pub const ResolutionKey = struct {
    file: FilePtr,
    expr: ExpressionPtr,
};

pub fn LookupKey(comptime T: type) type {
    return struct {
        scope: OpaquePtr,
        name: T,
    };
}

pub fn LookupContext(comptime T: type) type {
    return struct {
        const Self = @This();
        const Key = LookupKey(T);

        pub fn hash(_: Self, key: Key) u64 { 
            var hasher = std.hash.Wyhash.init(0);
            std.hash.autoHashStrat(&hasher, key, .DeepRecursive);
            return hasher.final();
        }

        // TODO: A more performant equality function
        pub fn eql(self: Self, a: Key, b: Key) bool {
            return self.hash(a) == self.hash(b);
        }
    };
}

pub fn LookupMap(comptime K: type, comptime V: type) type {
    return std.HashMapUnmanaged(LookupKey(K), V, LookupContext(K), std.hash_map.default_max_load_percentage);
}

pub fn ResolutionMap(comptime T: type) type {
    return std.AutoHashMapUnmanaged(ResolutionKey, T);
}
