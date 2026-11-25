const std = @import("std");
const node = @import("../../node.zig");
const failure = @import("../construction/publication.zig").failure;
const Lower = @import("../lower.zig");

pub fn field(self: *Lower, value: node.ExpressionId, seed: node.ExpressionId, name: []const u8) Lower.Error!node.ExpressionId {
    if (!@import("genz_options").generated_analysis) {
        var body: std.ArrayList(node.Statement) = .empty;

        try body.append(self.allocator, .{ .discard = value });

        const pointer = try self.builder.expression(.{ .address_of = try self.field(seed, name) });

        return @import("../aggregate.zig").finish(self, &body, pointer);
    }

    const entry = @import("generated_object_borrowed_field");
    const Input = std.meta.Child(entry.Input);

    const input: Input = .{
        .writer = @ptrCast(self),
        .frame = @ptrCast(self),
        .evaluated = @backingInt(value),
        .seed = @backingInt(seed),
        .name = name,
        .expression_base = @intCast(self.builder.nodes.expressions.tags.items.len),
        .statement_base = @intCast(self.builder.nodes.statements.tags.items.len),
        .serial = self.serial,
    };

    var buffer: [std.heap.page_size_min]u8 = undefined;
    var memory = std.heap.FixedBufferAllocator.init(&buffer);
    const root = entry.executeIn(memory.allocator(), &input) catch |err| return failure(err);

    return @fromBackingInt(root);
}
