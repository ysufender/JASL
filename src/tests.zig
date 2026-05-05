const std = @import("std");

test "All" {
    std.testing.refAllDecls(std);
}
