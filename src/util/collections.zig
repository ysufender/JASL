const std = @import("std");

const Error = @import("../core/common.zig").CompilerError;
const Allocator = std.mem.Allocator;

pub const MultiArrayList = @import("arraylist.zig").MultiArrayList;
pub const ReverseStackArray = @import("arraylist.zig").ReverseStackArray;

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

const IteratorTypeEnum = enum {
    Forward,
    Backward
};

fn IteratorType(T: type, Type: IteratorTypeEnum) type {
    return struct {
        const Self = @This();

        items: []const T,
        cur: u32,

        pub fn next(self: *Self) ?T {
            if (self.eos()) {
                return null;
            }

            switch (Type) {
                .Backward => {
                    self.cur -= 1;
                    return self.items[self.cur];
                },
                .Forward => {
                    defer self.cur += 1;
                    return self.items[self.cur];
                },
            }
        }

        pub fn eos(self: *const Self) bool {
            return switch (Type) {
                .Backward => self.cur <= 0,
                .Forward => self.cur >= self.items.len,
            };
        }

        pub fn reset(self: *Self) void {
            self.cur = switch (Type) {
                .Backward => self.items.len,
                .Forward => 0,
            };
        }
    };
}

pub fn SliceIterator(comptime Type: IteratorTypeEnum, items: anytype) IteratorType(@typeInfo(@TypeOf(items)).pointer.child, Type) {
    const T = @TypeOf(items);
    const info = @typeInfo(T);

    return switch (info) {
        .pointer => |p| switch (p.size) {
            .slice => .{
                .items = items,
                .cur = switch (Type) {
                    .Backward => @intCast(items.len),
                    .Forward => 0,
                },
            },
            else => @compileError("ReverseIterator requires a known-length slice."),
        },
        else => @compileError("ReverseIterator requires a known-length slice."),
    };
}

//
// Tests
//
const deepCopyArr = [_]u32{5, 4, 3, 4, 3};

test "Pointer Deep Copy" {
    const ptr = try std.testing.allocator.create(u32);
    ptr.* = 5;

    const ptr2 = try deepCopy(ptr, std.testing.allocator);

    defer std.testing.allocator.destroy(ptr);
    defer std.testing.allocator.destroy(ptr2);

    try std.testing.expectEqualDeep(ptr, ptr2);
    try std.testing.expect(ptr != ptr2);
}

test "Slice Deep Copy" {
    const ptr: []const u32 = &deepCopyArr;

    const ptr2 = try deepCopy(ptr, std.testing.allocator);

    defer std.testing.allocator.free(ptr2);

    try std.testing.expectEqualDeep(ptr, ptr2);
    try std.testing.expect(ptr.ptr != ptr2.ptr);
}

test "Many Pointer Shallow Copy" {
    const ptr: [*]const u32 = &deepCopyArr;

    const ptr2 = try deepCopy(ptr, std.testing.allocator);

    try std.testing.expect(ptr == ptr2);
}

test "C Pointer Shallow Copy" {
    const ptr: [*c]const u32 = &deepCopyArr;

    const ptr2 = try deepCopy(ptr, std.testing.allocator);

    try std.testing.expect(ptr == ptr2);
}

test "Optional Defined Pointer Copy" {
    const ptr: ?*u32 = try std.testing.allocator.create(u32);
    ptr.?.* = 5;

    const ptr2 = try deepCopy(ptr, std.testing.allocator);
    defer std.testing.allocator.destroy(ptr.?);
    defer std.testing.allocator.destroy(ptr2.?);

    try std.testing.expectEqualDeep(ptr, ptr2);
}

test "Optional Null Pointer Copy" {
    const ptr: ?*u32 = null;
    const ptr2 = try deepCopy(ptr, std.testing.allocator);

    try std.testing.expectEqualDeep(ptr, ptr2);
    try std.testing.expectEqualDeep(null, ptr);
}

test "Optional Defined Slice Copy" {
    const ptr: ?[] const u32 = &deepCopyArr;

    const ptr2 = try deepCopy(ptr, std.testing.allocator);
    defer std.testing.allocator.free(ptr2.?);
 
    try std.testing.expectEqualDeep(ptr, ptr2);
}

test "Optional Null Slice Copy" {
    const ptr: ?[]const u32 = null;
    const ptr2 = try deepCopy(ptr, std.testing.allocator);

    try std.testing.expectEqualDeep(ptr, ptr2);
    try std.testing.expectEqualDeep(null, ptr);
}

test "Optional Defined Array Copy" {
    const arr: ?[5]u32 = deepCopyArr;
    const arr2 = try deepCopy(arr, std.testing.allocator);

    try std.testing.expectEqualDeep(arr, arr2);
}

test "Optional Null Array Copy" {
    const arr: ?[5]u32 = null;
    const arr2 = try deepCopy(arr, std.testing.allocator);

    try std.testing.expectEqualDeep(arr, arr2);
    try std.testing.expectEqualDeep(arr2, null);
}

test "Array Copy" {
    const arr = try deepCopy(deepCopyArr, std.testing.allocator);

    try std.testing.expectEqualDeep(deepCopyArr, arr);
}

test "One Big Test" {
    const DeepNested = struct {
        const Self = @This();

        id: u32,
        data: ?[]const u8,
        children: ?[]Self,

        pub fn clone(self: Self, allocator: Allocator) !Self {
            var new_data: ?[]const u8 = null;
            if (self.data) |d| {
                new_data = try allocator.dupe(u8, d);
            }

            var new_children: ?[]Self = null;
            if (self.children) |children| {
                new_children = try allocator.alloc(Self, children.len);
                for (children, 0..) |child, i| {
                    new_children.?[i] = try child.clone(allocator);
                }
            }

            return .{
                .id = self.id,
                .data = new_data,
                .children = new_children,
            };
        }
    };

    const alloc = std.testing.allocator;

    var original = DeepNested{
        .id = 1,
        .data = try alloc.dupe(u8, "parent"),
        .children = try alloc.alloc(DeepNested, 1),
    };
    original.children.?[0] = .{
        .id = 2,
        .data = try alloc.dupe(u8, "child"),
        .children = null,
    };

    const copy = try deepCopy(original, alloc);

    defer {
        alloc.free(original.data.?);
        alloc.free(original.children.?[0].data.?);
        alloc.free(original.children.?);
        alloc.free(copy.data.?);
        alloc.free(copy.children.?[0].data.?);
        alloc.free(copy.children.?);
    }

    try std.testing.expectEqual(@as(u32, 1), copy.id);
    try std.testing.expect(std.mem.eql(u8, "parent", copy.data.?));
    try std.testing.expect(std.mem.eql(u8, "child", copy.children.?[0].data.?));
    
    try std.testing.expect(original.data.?.ptr != copy.data.?.ptr);
}
