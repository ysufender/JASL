const std = @import("std");
const parser = @import("parser.zig");
const common = @import("../core/common.zig");

pub const Table = struct {
    ast: u32,
};

pub const Prepass = struct {
    const Self = @This();

    lock: std.Thread.RwLock,
};
