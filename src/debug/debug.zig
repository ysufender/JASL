const std = @import("std");

const common = @import("../core/common.zig");
pub const ASTPrinter = @import("ast_printer.zig");

const Error = common.CompilerError;

pub fn NotImplemented(comptime src: std.builtin.SourceLocation) Error {
    common.log.err(std.fmt.comptimePrint("Unimplemented in {s} at {d}:{d}", .{
        src.file,
        src.line,
        src.column,
    }), .{});

    return Error.NotImplemented;
}

pub fn ShouldBeImpossible(comptime src: std.builtin.SourceLocation) Error {
    common.log.err(std.fmt.comptimePrint("Reached impossible branch in {s} at {d}:{d}", .{
        src.file,
        src.line,
        src.column,
    }), .{});

    return Error.NotImplemented;
}
