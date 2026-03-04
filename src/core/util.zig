const std = @import("std");

pub fn println(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) void {
    const str = std.fmt.allocPrint(allocator, fmt ++ "\n", args) catch return;
    defer allocator.free(str);

    _ = std.fs.File.stdout().write(str) catch 0;
}

pub fn print(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) void {
    const str = std.fmt.allocPrint(allocator, fmt, args) catch return;
    defer allocator.free(str);

    _ = std.fs.File.stdout().write(str) catch 0;
}
