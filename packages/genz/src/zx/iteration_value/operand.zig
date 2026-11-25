const std = @import("std");
const ir = @import("zx").ir;
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");
const failure = @import("../construction/publication.zig").failure;
const Self = @This();

name: []const u8,
value: node.ExpressionId,
reference: node.ExpressionId,
pub const empty: Self = .{ .name = &.{}, .value = @fromBackingInt(0), .reference = @fromBackingInt(0) };

pub fn lower(lowering: *Lower, id: ir.ExprId) Lower.Error!Self {
    return bind(lowering, try lowering.expr(id));
}

pub noinline fn bind(lowering: *Lower, value: node.ExpressionId) Lower.Error!Self {
    const entry = @import("generated_operand_reference");
    const Input = std.meta.Child(entry.Input);

    const input: Input = .{
        .writer = @ptrCast(lowering),
        .frame = @ptrCast(lowering),
        .expression_base = @intCast(lowering.builder.nodes.expressions.tags.items.len),
        .serial = lowering.serial,
    };

    var scratch = std.heap.ArenaAllocator.init(lowering.workspace);
    var buffer: [std.heap.page_size_min]u8 = undefined;
    var memory = std.heap.BufferFirstAllocator.init(&buffer, scratch.allocator());

    defer scratch.deinit();

    const output = entry.executeIn(memory.allocator(), &input) catch |err| return failure(err);

    return .{ .name = output.name, .value = value, .reference = @fromBackingInt(output.root) };
}
