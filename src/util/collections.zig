const std = @import("std");

const Error = @import("../core/common.zig").CompilerError;
const Allocator = std.mem.Allocator;

pub const MultiArrayList = @import("arraylist.zig").MultiArrayList;
pub const ReverseStackArray = @import("arraylist.zig").ReverseStackArray;

const hasMethod = std.meta.hasMethod;

pub fn deepCopySlice(T: type, slice: []const T, allocator: Allocator) Error![]T {
    var base = allocator.dupe(T, slice) catch return error.AllocatorFailure;

    for (slice, 0..) |from, i| {
        base[i] = try deepCopy(from, allocator);
    }

    return base;
}

pub fn deepCopy(item: anytype, allocator: Allocator) Error!@TypeOf(item) {
    const T = @TypeOf(item);
    const info = @typeInfo(T);

    switch (info) {
        .pointer => return deepCopySlice(info.pointer.child, item, allocator),
        .@"struct" => {
            const copy = @as(?[]const u8,
                if (hasMethod(T, "dupe")) "dupe"
                else if (hasMethod(T, "clone")) "clone"
                else null
            );

            if (copy) |func| {
                const copyFunc = @TypeOf(@field(T, func));
                const args = std.meta.ArgsTuple(copyFunc);

                return (
                    if (@typeInfo(args).@"struct".fields[0].type == *const T)
                        @call(.auto, @field(T, func), .{&item, allocator})
                    else
                        @call(.auto, @field(T, func), .{item, allocator})
                ) catch error.AllocatorFailure;

            }
            else {
                var ret: T = undefined;

                inline for (info.@"struct".fields) |field| {
                    @field(ret, field.name) =
                        try deepCopy(@field(item, field.name), allocator);
                }

                return ret;
            }
        },
        else => return item,
    }

    unreachable;
}
