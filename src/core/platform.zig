const builtin = @import("builtin");
const std = @import("std");

pub const isPosix = switch (builtin.target.os.tag) {
    .linux, .macos, .freebsd, .netbsd, .openbsd, .dragonfly => true,
    else => false,
};

pub const hasSIMD = 
        builtin.target.cpu.has(.arm, .neon)
        or builtin.target.cpu.has(.aarch64, .neon)
        or builtin.target.cpu.has(.aarch64, .sve)
        or builtin.target.cpu.has(.wasm, .simd128)
        or builtin.target.cpu.has(.x86, .sse)
        or builtin.target.cpu.has(.x86, .mmx)
        or builtin.target.cpu.has(.x86, .avx2);
