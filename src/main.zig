const std = @import("std");
const common = @import("core/common.zig");
const util = @import("core/util.zig");
const lexer = @import("lexer/lexer.zig");

pub fn main() void {
    const allocator_t = std.heap.DebugAllocator(.{});
    var alc = allocator_t.init;
    const allocator = alc.allocator();

    var compilerSettings = parseCLI(allocator) catch |err| switch (err) {
        error.CLIError => {
            return;
        },
        error.UnhandledError => {
            return;
        }
    };
    defer compilerSettings.deinit(allocator);
}

fn parseCLI(allocator: std.mem.Allocator) common.CompilerError!common.CompilerSettings {
    var args = std.process.args();
    _ = args.skip();

    var file: ?[]const u8 = null;

    while (true) {
        const arg = args.next();

        switch (hash(arg)) {
            hash("--help") => printHelp(allocator),
            hash("--version") => printHeader(allocator),
            hash(null) => {
                break;
            },

            else => if (file != null) {
                util.println(allocator, "Unexpected commandline option {s}", .{arg.?});
                return error.CLIError;
            } else {
                file = arg;
            }
        }
    }
    
    return common.CompilerSettings.init(allocator, "", "");
}

fn printHeader(allocator: std.mem.Allocator) void {
    util.println(
        allocator,
        "The JASL Compiler:" ++
        "\n\tVersion: " ++ common.JASL_VERSION,
        .{}
    );
}

fn printHelp(allocator: std.mem.Allocator) void {
    printHeader(allocator);
    util.println(
        allocator,
        "\n\tUsage:\n\tjaslc <input_file> [flags]\n\n\tFlags:" ++
        "\n\t\t --help: Print this help message.",
        .{}
    );
}

fn hash(str: ?[]const u8) usize {
    if (str == null) {
        return 1;
    } else if (std.mem.eql(u8, str.?, "--help")) {
        return 2;
    } else if (std.mem.eql(u8, str.?, "--version")) {
        return 3;
    }

    else return 0;
}
