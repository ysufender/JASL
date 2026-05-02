const std = @import("std");

const Error = @import("../core/common.zig").CompilerError;

fn InnerStaticStack(comptime T: type, comptime Size: usize) type {
    return struct {
        const Self = @This();

        values: [Size]T = undefined,
        index: u32 = 0,

        pub fn push(stack: *Self, value: T) Error!void {
            if (stack.index >= Size) {
                return error.OutOfMemory;
            }

            defer stack.index += 1;
            stack.values[stack.index] = value;
        }

        pub fn pop(stack: *Self) ?T {
            if (stack.index <= 0) {
                return null;
            }

            defer stack.index -= 1;
            return stack.values[stack.index];
        }

        pub fn empty(stack: *const Self) bool {
            return stack.index == 0;
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

        pub fn push(stack: *Self, value: T) void {
            if (stack.top >= Size) {
                stack.top = 0;
                stack.size -= 1;
            }

            defer stack.top += 1;
            defer stack.size += 1;

            stack.values[stack.top] = value;
        }

        pub fn pop(stack: *Self) ?T {
            if (stack.top <= 0 and stack.size > 0) {
                stack.top = Size - 1;
            }
            else if (stack.top <= 0) {
                return null;
            }

            defer stack.top -= 1;
            defer stack.size -= 1;
            return stack.peek();
        }

        pub fn peek(stack: *const Self) ?T {
            const top =
                if (stack.top <= 0 and stack.size > 0) Size - 1
                else if (stack.top <= 0) return null
                else stack.top - 1;

            return stack.values[top];
        }

        pub fn empty(stack: *const Self) bool {
            return stack.size <= 0;
        }
    };
}
