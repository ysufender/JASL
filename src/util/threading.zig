const threading = @import("../core/defines.zig").threading;

pub fn OnlyIfThreading(T: type) type {
    return if (threading) T else void;
}
