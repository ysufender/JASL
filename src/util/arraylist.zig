const std = @import("std");
const Allocator = std.mem.Allocator;
const CompilerError = @import("../core/common.zig").CompilerError;

/// Faster for structs compared to std.MultiArrayList
pub fn MultiArrayList(comptime T: type) type {
    const info = switch (@typeInfo(T)) {
        .@"struct" => |info| info,
        else => @compileError("MultiArrayList is only available to structs"),
    };

    const fields = info.fields;

    var newFields: [fields.len]std.builtin.Type.StructField = undefined;
    
    for (fields, 0..) |field, i| {
        newFields[i] = .{
            .name = field.name,
            .type = []field.type,
            .default_value_ptr = null,
            .is_comptime = false,
            .alignment = @alignOf([]field.type),
        };
    }

    const InnerType = @Type(.{
        .@"struct" = .{
            .fields = &newFields,
            .layout = .auto,
            .is_tuple = false,
            .backing_integer = null,
            .decls = &.{}
        }
    });

    return struct {
        const Self = @This();

        /// Owned readonly slice
        pub const Slice = struct {
            inner: InnerType,
            len: u32,

            pub fn items(slice: *const Slice, comptime field: std.meta.FieldEnum(InnerType)) []const @typeInfo(std.meta.fieldInfo(InnerType, field).type).pointer.child {
                return @field(slice.inner, std.meta.fieldInfo(InnerType, field).name);
            }

            pub fn get(slice: *const Slice, index: u32) T {
                var ret: T = undefined;

                inline for (info.fields) |field| {
                    @field(ret, field.name) = @field(slice.inner, field.name)[index];
                }

                return ret;
            }

            /// Frees all owned memory, slice shouldn't be used after free.
            pub fn free(slice: *Slice, allocator: Allocator) void {
                inline for (info.fields) |field| {
                    allocator.free(@field(slice.inner, field.name));
                }

                slice = .{
                    .len = 0,
                    .inner = undefined,
                };
            }
        };

        inner: InnerType,
        len: u32,

        pub fn init(allocator: Allocator, cap: usize) CompilerError!Self {
            var self = Self{
                .len = 0,
                .inner = undefined,
            };

            inline for (info.fields) |field| {
                @field(self.inner, field.name) = &.{};
            }

            try self.ensureTotalCapacity(allocator, cap);

            return self;
        }

        pub fn ensureTotalCapacity(self: *Self, allocator: Allocator, cap: usize) CompilerError!void {
            const lastField = info.fields[info.fields.len - 1].name;

            if (@field(self.inner, lastField).len >= cap) {
                return;
            }

            inline for (info.fields) |field| {
                var new: []field.type = undefined;

                if (@field(self.inner, field.name).len != 0) {
                    if (allocator.remap(@field(self.inner, field.name), cap)) |mem| {
                        new = mem;
                    }
                    else {
                        const mem = allocator.alloc(field.type, cap) catch return error.AllocatorFailure;
                        @memcpy(mem, @field(self.inner, field.name));
                        allocator.free(@field(self.inner, field.name));
                        new = mem;
                    }
                }
                else {
                    new = allocator.alloc(field.type, cap) catch return error.AllocatorFailure;
                }

                @field(self.inner, field.name) = new;
            }
        }

        pub fn addOne(self: *Self, allocator: Allocator) CompilerError!u32 {
            const lastField = info.fields[info.fields.len - 1].name;

            if (self.len >= @field(self.inner, lastField).len) {
                try self.ensureTotalCapacity(allocator, @field(self.inner, lastField).len);
            }

            self.len += 1;
            return self.len - 1;
        }

        pub fn append(self: *Self, allocator: Allocator, element: T) CompilerError!void {
            const lastField = info.fields[info.fields.len - 1].name;

            if (@field(self.inner, lastField).len <= self.len) {
                try self.ensureTotalCapacity(allocator, @field(self.inner, lastField).len);
            }

            self.appendAssumeCapacity(element);
        }

        pub fn appendAssumeCapacity(self: *Self, element: T) void {
            inline for (info.fields) |array| {
                @field(self.inner, array.name)[self.len] = @field(element, array.name);
            }

            self.len += 1;
        }

        pub fn items(self: *const Self, comptime field: std.meta.FieldEnum(InnerType)) []const @typeInfo(std.meta.fieldInfo(InnerType, field).type).pointer.child {
            return @field(self.inner, std.meta.fieldInfo(InnerType, field).name);
        }

        pub fn get(self: *const Self, index: u32) T {
            var ret: T = undefined;

            inline for (info.fields) |field| {
                @field(ret, field.name) = @field(self.inner, field.name)[index];
            }

            return ret;
        }

        pub fn set(self: *Self, index: u32, value: T) void {
            inline for (info.fields) |field| {
                @field(self.inner, field.name)[index] = @field(value, field.name);
            }
        }

        pub fn capacity(self: *Self) u32 {
            return @intCast(@field(self.inner, info.fields[0].name).len);
        }

        /// Clears all internal data and releases the ownership
        /// self is uninitialized after this call. Self.init must be called
        /// before use.
        pub fn toOwnedSlice(self: *Self) Slice {
            const len = self.len;
            const inner = self.inner;

            self.len = 0;
            self.inner = undefined;

            return .{
                .len = len,
                .inner = inner,
            };
        }
    };
}
