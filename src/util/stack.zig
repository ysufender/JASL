const std = @import("std");

const Error = @import("../core/common.zig").CompilerError;

pub fn StaticStack(comptime T: type) type {
    return struct {
        const Self = @This();

        values: []T,
        index: u32,

        pub fn init(size: u32, allocator: std.mem.Allocator) Error!Self {
            return .{
                .values = allocator.alloc(T, size) catch return error.AllocatorFailure,
                .index = 0,
            };
        }

        pub fn push(self: *Self, value: T) Error!void {
            if (self.index >= self.values.len) {
                return error.OutOfMemory;
            }

            self.values[self.index] = value;
            self.index += 1;
        }

        pub fn pop(self: *Self) Error!T {
            if (self.index <= 0) {
                return error.IndexOutOfBounds;
            }

            defer self.index -= 1;
            return self.values[self.index];
        }

        pub fn empty(self: *const Self) bool {
            return self.index == 0;
        }
    };
}
