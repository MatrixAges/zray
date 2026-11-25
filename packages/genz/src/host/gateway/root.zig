const std = @import("std");
const zx = @import("zx");

pub fn render(allocator: std.mem.Allocator) std.mem.Allocator.Error![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);

    defer arena.deinit();

    var writer: zx.memory.ByteWriter = .{ .allocator = allocator };

    defer writer.deinit();

    const entry = @import("generated_gateway_host");
    const Input = std.meta.Child(entry.Input);
    const input: Input = .{ .writer = @ptrCast(&writer) };
    const valid = zx.columns.invoke(entry.executeValue, arena.allocator(), &input) catch |err| return failure(err);

    if (!valid) return error.OutOfMemory;

    return writer.finish();
}

fn failure(err: anyerror) std.mem.Allocator.Error {
    return switch (err) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => error.OutOfMemory,
        else => @panic("invalid Gateway host AST"),
    };
}
