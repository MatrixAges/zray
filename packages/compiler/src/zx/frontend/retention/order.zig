const std = @import("std");
const zx = @import("zx");
const Error = std.mem.Allocator.Error;

pub fn fill(allocator: std.mem.Allocator, tree: anytype, result: anytype) Error!void {
    const rule = @import("generated_parser_type_order_write");
    const Input = std.meta.Child(rule.Input);
    const fields_end = tree.nodes.len + tree.fields.len;
    const words = try allocator.alloc(u64, fields_end + tree.items.len);
    var heads = words[0..tree.nodes.len];
    var fields = words[tree.nodes.len..fields_end];
    var items = words[fields_end..];

    const input: Input = .{
        .tree = zx.columns.pointer(@FieldType(Input, "tree"), tree),
        .heads = @ptrCast(&heads),
        .fields = @ptrCast(&fields),
        .items = @ptrCast(&items),
    };

    var empty = std.heap.FixedBufferAllocator.init(&.{});

    rule.executeIn(empty.allocator(), &input) catch |err| return failure(err);

    result.* = .{ .heads = heads, .fields = fields, .items = items };
}

fn failure(err: anyerror) Error {
    return switch (err) {
        error.OutOfMemory, error.Overflow, error.IntegerOverflow => error.OutOfMemory,
        else => unreachable,
    };
}
