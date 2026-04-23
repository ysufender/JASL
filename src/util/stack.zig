const std = @import("std");

const Error = @import("../core/common.zig").CompilerError;

fn InnerStaticStack(comptime T: type, comptime Size: usize) type {
    return struct {
        const Self = @This();

        values: [Size]T = undefined,
        index: u32 = 0,

        pub fn push(self: *Self, value: T) Error!void {
            if (self.index >= Size) {
                return error.OutOfMemory;
            }

            defer self.index += 1;
            self.values[self.index] = value;
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

pub fn StaticStack(comptime T: type, comptime Size: usize) InnerStaticStack(T, Size) {
    return InnerStaticStack(T, Size){};
}

pub fn StaticRingStack(comptime T: type, comptime Size: usize) type {
    return struct {
        const Self = @This();

        values: [Size]T = undefined,
        top: u32 = 0,
        size: u32 = 0,

        pub fn push(self: *Self, value: T) void {
            if (self.top >= Size) {
                self.top = 0;
                self.size -= 1;
            }

            defer self.top += 1;
            defer self.size += 1;

            self.values[self.top] = value;
        }

        pub fn pop(self: *Self) ?T {
            if (self.top <= 0 and self.size > 0) {
                self.top = Size - 1;
            }
            else if (self.top <= 0) {
                return null;
            }

            defer self.top -= 1;
            defer self.size -= 1;
            return self.peek();
        }

        pub fn peek(self: *const Self) ?T {
            const top =
                if (self.top <= 0 and self.size > 0) Size - 1
                else if (self.top <= 0) return null
                else self.top - 1;

            return self.values[top];
        }

        pub fn empty(self: *const Self) bool {
            return self.size <= 0;
        }
    };
}
