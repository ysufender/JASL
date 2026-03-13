const std = @import("std");
const builtin = @import("builtin");

const platform = @import("../core/platform.zig");

const mem = std.mem;
const posix = std.posix;

const Allocator = std.mem.Allocator;

/// Attempts to utilize a huge page allocator on posix
/// compliant platforms to minimize page faults. Fallbacks
/// to standard C allocator.
pub const performanceAllocator =
    if (!platform.isPosix) HugePageAllocator.allocator()
    else std.heap.c_allocator;

var HugePageAllocator =
    if (platform.isPosix) struct {
        const Self = @This();

        pub fn allocator(self: *Self) mem.Allocator {
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

        fn alloc(_: *anyopaque, len: usize, alignment: mem.Alignment, retAddr: usize) ?[*]u8 {
            const huge_page_size = 2 * 1024 * 1024;
            const aligned_len = mem.alignForward(usize, len, huge_page_size);

            const ptr = posix.mmap(
                null,
                aligned_len,
                posix.PROT.READ | posix.PROT.WRITE,
                .{
                    .TYPE = .PRIVATE,
                    .ANONYMOUS = true,
                    .HUGETLB = true,
                },
                -1,
                0,
            ) catch return std.heap.c_allocator.rawAlloc(len, alignment, retAddr);

            return ptr.ptr;
        }

        fn resize(_: *anyopaque, buf: []u8, _: mem.Alignment, new_len: usize, _: usize) bool {
            const huge_page_size = 2 * 1024 * 1024;
            return mem.alignForward(usize, new_len, huge_page_size) <= 
                   mem.alignForward(usize, buf.len, huge_page_size);
        }

        fn remap(_: *anyopaque, buf: []u8, _: mem.Alignment, new_len: usize, _: usize) ?[*]u8 {
            const mrmp = posix.MREMAP {
                .MAYMOVE = true,
            };

            const huge_page_size = 2 * 1024 * 1024;
            const aligned_old = mem.alignForward(usize, buf.len, huge_page_size);
            const aligned_new = mem.alignForward(usize, new_len, huge_page_size);

            if (aligned_new <= aligned_old) return buf.ptr;

            const aligned_ptr: [*]align(4096) u8 = @alignCast(buf.ptr);

            const new_slice = posix.mremap(
                aligned_ptr, 
                aligned_old,
                aligned_new,
                mrmp,
                null,
            ) catch return null;

            return new_slice.ptr;
        }

        fn free(_: *anyopaque, buf: []u8, _: mem.Alignment, _: usize) void {
            const huge_page_size = 2 * 1024 * 1024;
            const aligned_len = mem.alignForward(usize, buf.len, huge_page_size);
            
            const aligned_ptr: [*]align(4096) const u8 = @alignCast(buf.ptr);
            posix.munmap(aligned_ptr[0..aligned_len]);
        }
    } { }
    else null;
