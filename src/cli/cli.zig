const std = @import("std");

pub const CompilerSettings = struct {
    input_file: []u8,
    debug: bool,

    pub fn print(self: *const CompilerSettings) void {
        std.debug.print(
            "Input File: {s}\nDebug: {}\n",
            .{self.input_file, self.debug}
        );
    }
};

pub fn parseCLI(allocator: std.mem.Allocator) error{void}!CompilerSettings {
    const args = std.process.argsAlloc(allocator) catch {
        std.debug.print("Error while getting CLI args", .{});
        return error.void;
    };
    defer std.process.argsFree(allocator, args);

    var settings: CompilerSettings = .{
        .input_file = "",
        .debug = false
    };

    while (true) {
        const arg = shift(args) catch break;
        if (std.mem.eql(u8, arg, "--debug")) {
            settings.debug = true;
        } else if (settings.input_file.len == 0) {
            settings.input_file =
                allocator.alloc(u8, arg.len)
                catch return error.void;

            @memcpy(settings.input_file, arg);
        } else {
            std.debug.print("Unknown command line parameter {s}\n", .{arg});
            return error.void;
        }
    }

    return settings;
}

fn shift(args: []const []const u8) error{void}![]const u8 {
    const static = struct {
        var idx: usize = 1;
    };

    if (static.idx >= args.len)
        return error.void;

    const arg = args[static.idx];
    static.idx += 1;
    return arg;
}
