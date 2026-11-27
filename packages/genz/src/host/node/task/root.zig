const std = @import("std");
const zx = @import("zx");

pub fn render(allocator: std.mem.Allocator, stateful: bool) std.mem.Allocator.Error![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);

    defer arena.deinit();

    const workspace = arena.allocator();
    var writer: zx.memory.ByteWriter = .{ .allocator = allocator };

    defer writer.deinit();

    const entry = @import("generated_node_task");
    const Input = std.meta.Child(entry.Input);

    const input: Input = .{
        .stateful = stateful,
    };

    const result = zx.columns.invoke(entry.executeValue, workspace, &input) catch |err| return failure(err);

    try @import("../../../printer/module.zig").writeChunks(&writer, result orelse return error.OutOfMemory);

    return writer.finish();
}

fn failure(err: anyerror) std.mem.Allocator.Error {
    return switch (err) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => error.OutOfMemory,
        else => @panic("invalid Node task AST"),
    };
}
