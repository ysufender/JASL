const std = @import("std");

fn Context(comptime Key: type) type {
    return struct {
        const Self = @This();

        pub fn hash(_: Self, key: Key) u64 { 
            var hasher = std.hash.Wyhash.init(0);
            // TODO: Sometimes errors when '.DeepRecursive' is used.
            // Might be problematic.
            std.hash.autoHashStrat(&hasher, key, .DeepRecursive);
            return hasher.final();
        }

        // TODO: A more performant equality function
        pub fn eql(self: Self, a: Key, b: Key) bool {
            return self.hash(a) == self.hash(b);
        }
    };
}

pub fn HashMap(comptime Key: type, comptime Value: type) type {
    return std.HashMapUnmanaged(Key, Value, Context(Key), std.hash_map.default_max_load_percentage);
}
