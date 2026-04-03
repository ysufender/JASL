comptime {
    _ = @import("util/collections.zig").Tests;
    _ = @import("lexer/lexer.zig").Tests;
    _ = @import("parser/parser.zig").Tests;
}
