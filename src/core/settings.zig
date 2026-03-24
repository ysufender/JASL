const log = @import("log.zig");

const Self = @This();

pub const threading = true;

inputFile: []const u8,
workingDir: []const u8,
maxErr: u32,

pub fn print(self: *const Self) void {
    log.info(
        "Compilation settings\n\tInput File: {s}\n\tWorking Dir: {s}\n",
        .{self.inputFile, self.workingDir}
    );
}
