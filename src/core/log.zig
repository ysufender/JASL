const std = @import("std");
const builtin = @import("builtin");

pub fn info(comptime fmt: []const u8, args: anytype) void {
    if (!builtin.is_test) {
        std.log.info(fmt, args);
    }
}
pub fn warn(comptime fmt: []const u8, args: anytype) void {
    if (!builtin.is_test) {
        std.log.warn(fmt, args);
    }
}
pub fn err(comptime fmt: []const u8, args: anytype) void {
    if (!builtin.is_test) {
        std.log.err(fmt, args);
    }
}
pub fn print(comptime fmt: []const u8, args: anytype) void {
    var wbuf = struct {
        pub var wbuf = std.mem.zeroes([512]u8);
    }.wbuf;

    if (!builtin.is_test) {
        const stdout = std.fs.File.stdout();
        var writer = stdout.writer(&wbuf);
        writer.interface.print(fmt, args) catch undefined;
        writer.interface.flush() catch undefined;
    }
}

pub fn debug(comptime fmt: []const u8, args: anytype) void {
    if (!builtin.is_test) {
        std.log.debug(fmt, args);
    }
}
