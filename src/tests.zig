comptime {
    _ = @import("lexer/lexer.zig").Tests;
    _ = @import("parser/parser.zig").Tests;
    _ = @import("util/arraylist.zig").Tests;
}
