const Lower = @import("../lower.zig");

pub inline fn snapshot(comptime Bases: type, self: *const Lower) Bases {
    return .{
        .capture = if (self.capture) |capture| &.{
            .name = capture.name,
            .label = capture.label,
            .failure = @backingInt(capture.failure),
        } else null,
        .expression_base = @intCast(self.builder.nodes.expressions.tags.items.len),
        .statement_base = @intCast(self.builder.nodes.statements.tags.items.len),
        .field_base = @intCast(self.builder.nodes.field_columns.count()),
        .serial = self.serial,
    };
}
