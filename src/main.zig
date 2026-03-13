const std = @import("std");
const viewer = @import("viewer.zig");

pub fn main() !void {
    try viewer.run(std.heap.page_allocator);
}
