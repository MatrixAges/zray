const std = @import("std");
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");
const aggregate = @import("../aggregate.zig");
const object_fields = @import("../aggregate/object.zig");

pub const Source = union(enum) {
    value: node.ExpressionId,
    tuple: struct { layout: node.ExpressionId, values: []const node.ExpressionId },
    object: struct { request: object_fields.Request, scratch: std.mem.Allocator },
};

pub fn lower(self: *Lower, body: anytype, source: Source) Lower.Error!node.ExpressionId {
    comptime std.debug.assert(!@import("genz_options").generated_analysis);

    const value = switch (source) {
        .value => |value| value,
        .tuple => |tuple| try self.cast(tuple.layout, try self.builder.expression(.{ .tuple = tuple.values })),
        .object => |object| try object_fields.lower(self, object.scratch, object.request),
    };

    const reference = try aggregate.bind(self, body, value);

    return self.builder.expression(.{ .address_of = reference });
}
