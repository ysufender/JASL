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

pub fn debug(comptime fmt: []const u8, args: anytype) void {
    if (!builtin.is_test) {
        std.log.debug(fmt, args);
    }
}

pub var wbuf = std.mem.zeroes([512]u8);
pub fn print(io: std.Io, comptime fmt: []const u8, args: anytype) void {
    if (!builtin.is_test) {
        const stdout = std.Io.File.stdout();
        var writer = stdout.writer(io, &wbuf);
        writer.interface.print(fmt, args) catch undefined;
        writer.interface.flush() catch undefined;
    }
}
