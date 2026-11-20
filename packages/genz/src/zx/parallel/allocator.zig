const std = @import("std");
const Lower = @import("../lower.zig");

pub fn append(self: *Lower, output: *@import("../../node/declarations.zig").Output) Lower.Error!void {
    const value = try @import("../allocator.zig").lower(self, false);

    if (!@import("genz_options").generated_analysis) return output.append(self.allocator, .{ .constant = .{ .name = "zx_parallel_allocator", .value = value } });

    const entry = @import("generated_parallel_allocator_alias");
    var scratch = std.heap.ArenaAllocator.init(self.workspace);
    var buffer: [std.heap.page_size_min]u8 = undefined;
    var memory = std.heap.BufferFirstAllocator.init(&buffer, scratch.allocator());

    defer scratch.deinit();

    const columns = entry.executeIn(memory.allocator(), @backingInt(value)) catch |err| return failure(err);

    output.appendColumns(self.allocator, columns, true) catch |err| return failure(err);
}

fn failure(err: anyerror) Lower.Error {
    return switch (err) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => error.OutOfMemory,
        else => unreachable,
    };
}
