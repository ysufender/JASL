const std = @import("std");
const common = @import("common.zig");

pub const JASL_VERSION = "0.0.1";

pub const CompilerSettings = struct {
    inputFile: []u8,
    workingDir: []u8,

    const Self = @This();

    pub fn init(
        allocator: std.mem.Allocator,
        inputFile: []const u8,
        workingDir: []const u8
    ) common.CompilerError!Self {
        var self = Self {
            .inputFile = allocator.alloc(u8, inputFile.len) catch return error.InternalError,
            .workingDir = allocator.alloc(u8, workingDir.len) catch return error.InternalError
        };

        @memcpy(self.inputFile, inputFile);
        @memcpy(self.workingDir, workingDir);

        return self;
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        allocator.free(self.inputFile);
        allocator.free(self.workingDir);
    }

    pub fn print(self: *const Self) void {
        std.log.info(
            "Compilation settings\n\tInput File: {s}\n\tWorking Dir: {s}\n",
            .{self.inputFile, self.workingDir}
        );
    }
};

pub const CompilerError = error {
    MissingFlag,
    UnknownFlag,
    InternalError,
    NoSourceFile,
    IOError,
    InvalidToken,
    UnterminatedComment,
    UnterminatedStringLiteral,
};
