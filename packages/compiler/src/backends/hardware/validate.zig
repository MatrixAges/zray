const std = @import("std");
const ir = @import("ir.zig");

pub fn validate(module: ir.Module) bool {
    var view: @import("graph/view.zig") = undefined;
    var scratch: std.heap.ArenaAllocator = .init(std.heap.page_allocator);

    defer scratch.deinit();

    const allocator = scratch.allocator();

    view.init(allocator, module) catch return false;

    return view.validate(allocator);
}
