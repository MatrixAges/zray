const std = @import("std");
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");
const aggregate = @import("../aggregate.zig");
const object_fields = @import("../aggregate/object.zig");
const failure = @import("../construction/publication.zig").failure;

pub const Source = union(enum) {
    value: node.ExpressionId,
    tuple: struct { layout: node.ExpressionId, values: []const node.ExpressionId },
    object: struct { request: object_fields.Request, scratch: std.mem.Allocator },
};

pub fn lower(self: *Lower, body: anytype, source: Source) Lower.Error!node.ExpressionId {
    if (!@import("genz_options").generated_analysis) {
        const value = switch (source) {
            .value => |value| value,
            .tuple => |tuple| try self.cast(tuple.layout, try self.builder.expression(.{ .tuple = tuple.values })),
            .object => |object| try object_fields.lower(self, object.scratch, object.request),
        };

        const reference = try aggregate.bind(self, body, value);

        return self.builder.expression(.{ .address_of = reference });
    }

    std.debug.assert(source == .value);

    const entry = @import("generated_value_argument_borrow");
    const Input = std.meta.Child(entry.Input);

    const input: Input = .{
        .writer = @ptrCast(self),
        .frame = @ptrCast(self),
        .sequence = @ptrCast(body),
        .value = @backingInt(source.value),
        .layout = null,
        .values = &.{},
        .expression_base = @intCast(self.builder.nodes.expressions.tags.items.len),
        .serial = self.serial,
        .object = null,
    };

    var buffer: [std.heap.page_size_min]u8 = undefined;
    var memory = std.heap.FixedBufferAllocator.init(&buffer);
    const root = entry.executeIn(memory.allocator(), &input) catch |err| return failure(err);

    return @fromBackingInt(root);
}
