const std = @import("std");
const log = @import("log.zig");

const Self = @This();

inputFile: []const u8,
workingDir: []const u8,
includeDirs: [][]const u8,
maxErr: u32,

pub fn print(self: *const Self, allocator: std.mem.Allocator) void {
    log.info(
        "Compilation settings:"
        ++ "\n\tInput File: {s}"
        ++ "\n\tWorking Dir: {s}"
        ++ "\n\tInclude Dirs: [{s}]\n",
        .{self.inputFile, self.workingDir, std.mem.join(allocator, ", ", self.includeDirs) catch ""}
    );
}
