const std = @import("std");
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");

pub fn span(self: *Lower, comptime entry: type, input: entry.Input) Lower.Error!node.Block {
    var scratch = std.heap.ArenaAllocator.init(self.workspace);
    var buffer: [std.heap.page_size_min]u8 = undefined;
    var memory = std.heap.BufferFirstAllocator.init(&buffer, scratch.allocator());

    defer scratch.deinit();

    const encoded = entry.executeIn(memory.allocator(), input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => return error.OutOfMemory,
        else => unreachable,
    };

    return @import("../construction/publication.zig").unpackSpan(encoded);
}
