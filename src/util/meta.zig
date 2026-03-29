const std = @import("std");

pub fn matchMethod(comptime T: type, comptime func: []const u8, comptime args: anytype, comptime ret: type) bool {
    if (!std.meta.hasMethod(T, func)) {
        return false;
    }

    for (std.meta.fields(args), std.meta.ArgsTuple(@field(T, func))) |expected, got| {
        if (expected != got) {
            return false;
        }
    }

    return
        if (@typeInfo(@field(T, func)).@"fn".return_type) |r| r == ret
        else ret == void;
}
