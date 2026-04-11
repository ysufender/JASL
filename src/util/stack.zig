const std = @import("std");

const Error = @import("../core/common.zig").CompilerError;

fn InnerStaticStack(comptime T: type, comptime size: usize) type {
    return struct {
        const Self = @This();

        values: [size]T = undefined,
        index: u32 = 0,

        pub fn push(self: *Self, value: T) Error!void {
            if (self.index >= self.values.len) {
                return error.OutOfMemory;
            }

            self.values[self.index] = value;
            self.index += 1;
        }

        pub fn pop(self: *Self) ?T {
            if (self.index <= 0) {
                return null;
            }

            defer self.index -= 1;
            return self.values[self.index];
        }

        pub fn empty(self: *const Self) bool {
            return self.index == 0;
        }
    };
}

pub fn StaticStack(comptime T: type, comptime size: usize) InnerStaticStack(T, size) {
    return InnerStaticStack(T, size){};
}
