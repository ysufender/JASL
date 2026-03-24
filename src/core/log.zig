const std = @import("std");
const builtin = @import("builtin");

pub const info = if (builtin.is_test) emptyLog else std.log.info;
pub const warn = if (builtin.is_test) emptyLog else std.log.warn;
pub const err = if (builtin.is_test) emptyLog else std.log.err;

fn emptyLog(comptime _: []const u8, _: anytype) void { }
