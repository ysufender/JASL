const std = @import("std");
const builtin = std.builtin;
const compilation = @import("builtin");

const cli = @import("cli/cli.zig");

var allocator_t = std.heap.DebugAllocator(.{}){};
const allocator = allocator_t.allocator();

pub fn main() void {
    const settings = cli.parseCLI(allocator) catch return;

    if (compilation.mode == builtin.OptimizeMode.Debug) {
        settings.print();
    }
}
