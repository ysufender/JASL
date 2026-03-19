const std = @import("std");
const parser = @import("parser.zig");

pub const Prepass = struct {
    const Self = @This();

    table: parser.Parser.Table,

    pub fn init(table: parser.Parser.Table) Self {
        return .{
            .table = table,
        };
    }
};
