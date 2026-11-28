const std = @import("std");
const zx = @import("zx");
const Error = std.mem.Allocator.Error;

pub fn fill(allocator: std.mem.Allocator, tree: anytype, result: anytype) Error!void {
    const rule = @import("generated_parser_type_order_write");
    const Input = std.meta.Child(rule.Input);
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);

    defer arena.deinit();

    var scratch_buf: [2048]u8 = undefined;
    var fallback = std.heap.BufferFirstAllocator.init(&scratch_buf, arena.allocator());
    const tree_view = zx.columns.view(Input, tree);
    const order = rule.executeValue(fallback.allocator(), &tree_view) catch |err| return failure(err);
    const fields_end = order.heads.len + order.fields.len;
    const words = try allocator.alloc(u64, fields_end + order.items.len);
    const heads = words[0..order.heads.len];
    const fields = words[order.heads.len..fields_end];
    const items = words[fields_end..];

    @memcpy(heads, order.heads);
    @memcpy(fields, order.fields);
    @memcpy(items, order.items);

    result.* = .{ .heads = heads, .fields = fields, .items = items };
}

fn failure(err: anyerror) Error {
    return switch (err) {
        error.OutOfMemory, error.Overflow, error.IntegerOverflow => error.OutOfMemory,
        else => unreachable,
    };
}
