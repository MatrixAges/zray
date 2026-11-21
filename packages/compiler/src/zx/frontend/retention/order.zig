const std = @import("std");
const zx = @import("zx");
const Table = std.meta.Child(@import("generated_parser").Output);
const Error = std.mem.Allocator.Error;
const Destination = enum { temporary, retained };

const Frame = struct {
    allocator: std.mem.Allocator,
    tree: *Table,
    destination: Destination,
};

pub fn publish(allocator: std.mem.Allocator, output: anytype, comptime destination: Destination) Error!void {
    const syntax = @constCast(output);

    if (comptime @hasField(std.meta.Child(@TypeOf(output)), "constants")) {
        const rule = @import("generated_parser_publish_orders");
        var frame: Frame = .{ .allocator = allocator, .tree = syntax, .destination = destination };
        var empty = std.heap.FixedBufferAllocator.init(&.{});
        const input: std.meta.Child(rule.Input) = .{ .output = @ptrCast(&frame), .constants = syntax.constants.len };

        return rule.executeIn(empty.allocator(), &input) catch |err| failure(err);
    }

    try install(allocator, syntax, destination);
}

pub fn publishSyntaxOrder(handle: *const anyopaque, constant: ?u64) Error!void {
    const frame: *const Frame = @ptrCast(@alignCast(handle));

    if (constant) |row| {
        try install(frame.allocator, @constCast(frame.tree.constants[@intCast(row)]), frame.destination);
    } else {
        try install(frame.allocator, frame.tree, frame.destination);
    }
}

fn install(allocator: std.mem.Allocator, output: anytype, destination: Destination) Error!void {
    const rule = @import("generated_parser_type_order_write");
    const Input = std.meta.Child(rule.Input);
    const Order = std.meta.Child(@TypeOf(output.type_order));
    const tree = output.types;
    const fields_end = tree.nodes.len + tree.fields.len;
    const words = try allocator.alloc(u64, fields_end + tree.items.len);
    var heads = words[0..tree.nodes.len];
    var fields = words[tree.nodes.len..fields_end];
    var items = words[fields_end..];
    const result = if (destination == .retained) @constCast(output.type_order) else try allocator.create(Order);

    const input: Input = .{
        .tree = zx.columns.pointer(@FieldType(Input, "tree"), tree),
        .heads = @ptrCast(&heads),
        .fields = @ptrCast(&fields),
        .items = @ptrCast(&items),
    };

    var empty = std.heap.FixedBufferAllocator.init(&.{});

    rule.executeIn(empty.allocator(), &input) catch |err| return failure(err);

    result.* = .{ .heads = heads, .fields = fields, .items = items };
    output.type_order = result;
}

fn failure(err: anyerror) Error {
    return switch (err) {
        error.OutOfMemory, error.Overflow, error.IntegerOverflow => error.OutOfMemory,
        else => unreachable,
    };
}
