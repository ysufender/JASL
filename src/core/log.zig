const std = @import("std");
const builtin = @import("builtin");

pub const info = if (builtin.is_test) emptyLog else std.log.info;
pub const warn = if (builtin.is_test) emptyLog else std.log.warn;
pub const err = if (builtin.is_test) emptyLog else std.log.err;
pub const print = if (builtin.is_test) emptyLog else _print;

var wbuf = std.mem.zeroes([512]u8);
const stdout = std.fs.File.stdout();
var writer = stdout.writer(&wbuf);

fn emptyLog(comptime _: []const u8, _: anytype) void { }
fn _print(comptime fmt: []const u8, args: anytype) void {
    writer.interface.print(fmt, args) catch undefined;
    writer.interface.flush() catch undefined;
}
