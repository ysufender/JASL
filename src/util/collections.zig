const std = @import("std");

const Error = @import("../core/common.zig").CompilerError;
const Allocator = std.mem.Allocator;

pub const MultiArrayList = @import("arraylist.zig").MultiArrayList;
pub const ReverseStackArray = @import("arraylist.zig").ReverseStackArray;
pub const StaticStack = @import("stack.zig").StaticStack;
pub const HashMap = @import("hashmap.zig").HashMap;

fn determine(comptime ptr: type) struct {
    PtrType: std.builtin.Type.Pointer.Size,
    ElemType: type,
    SelfType: type,
} {
    return switch (@typeInfo(ptr)) {
        .pointer => |p| .{
            .PtrType = p.size,
            .ElemType = p.child,
            .SelfType = switch (p.size) {
                .one => *p.child,
                .many => ptr,
                .slice => []p.child,
                .c => ptr,
            },
        },
        else => @compileError("Expected pointer type."),
    };
}

/// Attempts deep copy depending on the passed ptr type
/// - One: deep copy
/// - Slice: Deep copy each element
/// - Many: Shallow Copy
/// - C: Shallow Copy
pub fn deepCopyPtr(ptr: anytype, allocator: Allocator) Error!determine(@TypeOf(ptr)).SelfType {
    const info = determine(@TypeOf(ptr));

    var result: info.SelfType = undefined;

    switch (info.PtrType) {
        .one => {
            result = allocator.create(info.ElemType) catch return error.AllocatorFailure;
            result.* = try deepCopy(ptr.*, allocator);
        },
        .many => result = ptr,
        .slice => {
            result = allocator.alloc(info.ElemType, ptr.len) catch return error.AllocatorFailure;
            for (0..ptr.len) |i| {
                result[i] = try deepCopy(ptr[i], allocator);
            }
        },
        .c => result = ptr,
    }

    return result;
}

/// Attempts to deep copy a value,
/// - If value is a pointer/slice, calls deepCopyPtr
/// - If value is a struct, and contains a method with name "dupe" or "clone"
/// with signature fn (*const Self, Allocator) Self or fn (Self, Allocator) Self,
/// calls it.
/// - Otherwise performs a shallow copy.
pub fn deepCopy(item: anytype, allocator: Allocator) Error!@TypeOf(item) {
    const T = @TypeOf(item);
    const info = @typeInfo(T);

    switch (info) {
        .pointer => return deepCopyPtr(item, allocator),
        .@"struct" => |obj| {
            const copy = @as(?[]const u8,
                if (std.meta.hasMethod(T, "dupe")) "dupe"
                else if (std.meta.hasMethod(T, "clone")) "clone"
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

                inline for (obj.fields) |field| {
                    @field(ret, field.name) =
                        try deepCopy(@field(item, field.name), allocator);
                }

                return ret;
            }
        },
        .optional => {
            return
                if (item) |underlying| try deepCopy(underlying, allocator)
                else null;
        },
        .array => |arr| {
            var new: [arr.len]arr.child = undefined;

            if (arr.len <= 5) {
                inline for (0..arr.len) |i| {
                    new[i] = try deepCopy(item[i], allocator);
                }
            }
            else {
                for (0..arr.len) |i| {
                    new[i] = try deepCopy(item[i], allocator);
                }
            }

            return new;
        },
        else => return item,
    }

    unreachable;
}
