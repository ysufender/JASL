const std = @import("std");

fn Context(comptime Key: type) type {
    return struct {
        const Self = @This();

        pub fn hash(_: Self, key: Key) u64 { 
            var hasher = std.hash.Wyhash.init(0);
            std.hash.autoHashStrat(&hasher, key, .DeepRecursive);
            return hasher.final();
        }

        // TODO: A more performant equality function
        pub fn eql(_: Self, a: Key, b: Key) bool {
            return genericEql(a, b);
        }
    };
}

pub fn HashMap(comptime Key: type, comptime Value: type) type {
    return std.HashMapUnmanaged(Key, Value, Context(Key), std.hash_map.default_max_load_percentage);
}

pub fn genericEql(a: anytype, b: anytype) bool {
    const tag = std.meta.activeTag;

    return switch (@typeInfo(@TypeOf(a))) {
        .pointer => |ptr| switch (ptr.size) {
            .slice =>
                if (a.len != b.len) false
                else {
                    for (0..a.len) |i| {
                        if (!genericEql(a[i], b[i]))
                            return false;
                    }

                    return true;
                },
            else => @compileError("Not supported"),
        },
        .@"struct" => |structure| {
            inline for (structure.fields) |field| {
                if (!genericEql(@field(a, field.name), @field(b, field.name))) {
                    return false;
                }
            }

            return true;
        },
        .@"union" => |uni|
            if (tag(a) != tag(b)) false
            else {
                const t = tag(a);

                inline for (uni.fields) |field| {
                    if (
                        std.mem.eql(u8, field.name, @tagName(t))
                        and
                        !genericEql(@field(a, field.name), @field(b, field.name))
                    )
                        return false;
                }

                return true;
            },
        else => a == b,
    };
}
