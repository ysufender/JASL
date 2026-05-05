const std = @import("std");
const builtin = @import("builtin");

const platform = @import("../core/platform.zig");
const common = @import("../core/common.zig");

const mem = std.mem;
const posix = std.posix;
const windows = std.os.windows;

const Allocator = std.mem.Allocator;

/// Attempts to utilize a huge page allocator on posix
/// compliant platforms to minimize page faults. Fallbacks
/// to standard C allocator.
pub fn PerformanceAllocator(fallback: std.mem.Allocator) ?HugePageAllocator {
    return if (platform.isPosix) HugePageAllocator.init(fallback)
    else null;
}

const HugePageAllocator = struct {
    fallingBack: bool = false,
    fallback: std.mem.Allocator,

    pub fn init(fallback: std.mem.Allocator) HugePageAllocator {
        return .{ .fallback = fallback };
    }

    pub fn allocator(self: *HugePageAllocator) mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    fn alloc(_self: *anyopaque, len: usize, alignment: mem.Alignment, retAddr: usize) ?[*]u8 {
        const self = @as(*HugePageAllocator, @ptrCast(@alignCast(_self)));

        if (self.fallingBack) {
            return self.fallback.rawAlloc(len, alignment, retAddr);
        }

        const huge_page_size = 2 * 1024 * 1024;
        const aligned_len = mem.alignForward(usize, len, huge_page_size);

        const ptr = posix.mmap(
            null,
            aligned_len,
            .{
                .READ = true,
                .WRITE = true,
            },
            .{
                .TYPE = .PRIVATE,
                .ANONYMOUS = true,
                .HUGETLB = true,
            },
            -1,
            0,
        ) catch {
            common.log.debug("Huge pages failed, falling back to default.", .{});
            self.fallingBack = true;
            return self.fallback.rawAlloc(len, alignment, retAddr);
        };

        return ptr.ptr;
    }

    fn resize(_self: *anyopaque, buf: []u8, alignment: mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self = @as(*HugePageAllocator, @ptrCast(@alignCast(_self)));

        if (self.fallingBack) {
            return self.fallback.rawResize(buf, alignment, new_len, ret_addr);
        }

        const huge_page_size = 2 * 1024 * 1024;
        return mem.alignForward(usize, new_len, huge_page_size) <= mem.alignForward(usize, buf.len, huge_page_size);
    }

    fn remap(_self: *anyopaque, buf: []u8, alignment: mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self = @as(*HugePageAllocator, @ptrCast(@alignCast(_self)));

        if (self.fallingBack) {
            return self.fallback.rawRemap(buf, alignment, new_len, ret_addr);
        }

        const huge_page_size = 2 * 1024 * 1024;
        const aligned_old = mem.alignForward(usize, buf.len, huge_page_size);
        const aligned_new = mem.alignForward(usize, new_len, huge_page_size);

        if (aligned_new <= aligned_old) return buf.ptr;

        const aligned_ptr: [*]align(4096) u8 = @alignCast(buf.ptr);

        const new_slice = posix.mremap(
            aligned_ptr, 
            aligned_old,
            aligned_new,
            .{
                .MAYMOVE = true,
            },
            null,
        ) catch return null;

        return new_slice.ptr;
    }

    fn free(_self: *anyopaque, buf: []u8, alignment: mem.Alignment, ret_addr: usize) void {
        const self = @as(*HugePageAllocator, @ptrCast(@alignCast(_self)));

        if (self.fallingBack) {
            return self.fallback.rawFree(buf, alignment, ret_addr);
        }

        const huge_page_size = 2 * 1024 * 1024;
        const aligned_len = mem.alignForward(usize, buf.len, huge_page_size);
        
        const aligned_ptr: [*]align(4096) const u8 = @alignCast(buf.ptr);
        posix.munmap(aligned_ptr[0..aligned_len]);
    }
};
