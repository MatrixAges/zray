const std = @import("std");
const zx = @import("zx");
const State = @import("../state.zig");
const Group = zx.memory.ColumnRangeGroup;

pub fn frame(comptime Work: type) type {
    const Write = Child(Work, "write");
    const Range = Child(Write, "fields");

    return struct {
        const Self = @This();
        input: Work = undefined,
        allocation: Child(Work, "allocation") = undefined,
        write: Write = undefined,
        indices: Child(Write, "indices") = undefined,
        values: Child(Write, "values") = undefined,
        fields_range: Range = undefined,
        evaluation_range: Range = undefined,
        header: Child(Work, "header") = undefined,
        metadata: Child(Work, "metadata") = undefined,
        expression: Group(5) = .{},
        object: Group(4) = .{},
        members: Group(2) = .{},
        evaluation: Group(1) = .{},
        pub fn bind(self: *Self, state: *State) void {
            const storage = &state.builder.expressions;
            const count = state.evaluation.len;

            self.header = .{
                .kinds = @ptrCast(self.expression.bind(&storage.kinds, 1, true)),
                .types = @ptrCast(self.expression.bind(&storage.types, 1, false)),
                .starts = @ptrCast(self.expression.bind(&storage.span_start, 1, false)),
                .ends = @ptrCast(self.expression.bind(&storage.span_end, 1, false)),
                .payloads = @ptrCast(self.expression.bind(&storage.payloads, 1, false)),
            };

            self.fields_range = .{
                .firsts = @ptrCast(self.object.bind(&storage.object_first, 1, false)),
                .counts = @ptrCast(self.object.bind(&storage.object_count, 1, false)),
                .first = @intCast(storage.object_field_indices.items.len),
            };

            self.evaluation_range = .{
                .firsts = @ptrCast(self.object.bind(&storage.object_evaluation_first, 1, false)),
                .counts = @ptrCast(self.object.bind(&storage.object_evaluation_count, 1, false)),
                .first = @intCast(storage.object_evaluation_values.items.len),
            };

            self.indices = .{
                .source = state.names,
                .canonical = state.table.?.get(state.output).object.names,
                .positions = @ptrCast(self.members.bind(&storage.object_field_indices, count, false)),
            };

            self.values = .{
                .source = std.mem.sliceAsBytes(state.evaluation),
                .fields = @ptrCast(self.members.bind(&storage.object_field_values, count, true)),
                .evaluation = @ptrCast(self.evaluation.bind(&storage.object_evaluation_values, count, true)),
            };

            self.write = .{
                .indices = &self.indices,
                .values = &self.values,
                .fields = &self.fields_range,
                .evaluation = &self.evaluation_range,
            };

            self.metadata = .{
                .type_id = @backingInt(state.output),
                .span_start = State.span.start,
                .span_end = State.span.end,
            };

            const resource = &state.builder.allocator;

            self.allocation = .{
                .resource = @ptrCast(resource),
                .header = @ptrCast(self.object.freeze().?),
                .members = @ptrCast(self.members.freeze().?),
                .evaluation = @ptrCast(self.evaluation.freeze().?),
            };

            self.input = .{
                .resource = @ptrCast(resource),
                .expression = @ptrCast(self.expression.freeze().?),
                .allocation = &self.allocation,
                .write = &self.write,
                .header = &self.header,
                .metadata = &self.metadata,
                .kind = @backingInt(@as(std.meta.Elem(@FieldType(zx.ir.ExpressionTable, "kinds")), .Object)),
            };
        }
    };
}

fn Child(comptime Parent: type, comptime field: []const u8) type {
    return std.meta.Child(@FieldType(Parent, field));
}
