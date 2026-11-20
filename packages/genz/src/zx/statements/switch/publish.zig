const std = @import("std");
const zx = @import("zx");
const node = @import("../../../node.zig");
const view = @import("../../../node/view.zig");
const rows = @import("../../../node/import_rows.zig");
const Lower = @import("../../lower.zig");
const State = @import("state.zig");

pub fn lower(self: *Lower, state: *const State, allocator: std.mem.Allocator) Lower.Error!node.Block {
    const entry = @import("generated_switch_emit");
    const Input = std.meta.Child(entry.Input);
    const Output = std.meta.Child(entry.Output);
    const Cases = std.meta.Child(@FieldType(Input, "cases"));
    const Bases = std.meta.Child(@FieldType(Input, "bases"));
    const cases: Cases = .{ .body_start = state.starts, .body_count = state.counts, .conditions = state.comparisons, .literals = state.literals };

    const bases: Bases = .{
        .capture = null,
        .expression_base = @intCast(self.builder.nodes.expressions.tags.items.len),
        .statement_base = @intCast(self.builder.nodes.statements.tags.items.len),
        .field_base = @intCast(self.builder.nodes.field_columns.count()),
        .serial = self.serial,
    };

    const input: Input = .{
        .name = state.name,
        .subject = @backingInt(state.subject),
        .reference = @backingInt(state.reference),
        .selected = state.selected,
        .exhaustive = state.selection.exhaustive,
        .total_count = state.selection.cases.len,
        .fallback_start = if (state.fallback) |block| block.start else null,
        .fallback_count = if (state.fallback) |block| block.len else 0,
        .cases = &cases,
        .arm_base = @intCast(self.builder.nodes.arm_columns.count()),
        .bases = &bases,
    };

    const output = entry.executeIn(allocator, &input) catch |err| return failure(err);

    if (!output.valid) return error.OutOfMemory;

    const expression_rows = zx.columns.view(std.meta.Child(@FieldType(Output, "expressions")), output.expressions);
    const extra = zx.columns.view(std.meta.Child(@FieldType(Output, "extra")), output.extra);
    const expressions = view.join(expression_rows, extra);
    const arms = zx.columns.view(std.meta.Child(@FieldType(Output, "arms")), output.arms);
    @import("../../../node/import_arms.zig").append(self.allocator, &self.builder.nodes.arm_columns, &arms) catch |err| return failure(err);

    rows.appendBorrowingText(self.allocator, &self.builder.nodes.expressions, &expressions) catch |err| return failure(err);

    const physical = zx.columns.view(std.meta.Child(@FieldType(Output, "statements")), output.statements);
    var children = physical;

    children.tags = output.children.tags;
    children.offsets = output.children.offsets;
    @import("../../../node/import_selected.zig").append(self.allocator, &self.builder.nodes.statements, &children) catch |err| return failure(err);

    const node_storage = self.builder.nodes;
    const start: u32 = @intCast(node_storage.statements.tags.items.len);
    const count: u32 = @intCast(physical.tags.len);

    @import("../../../node/import_selected.zig").appendBorrowingText(self.allocator, &node_storage.statements, &physical) catch |err| return failure(err);

    return @import("../../../node/blocks.zig").join(
        self.allocator,
        node_storage,
        &.{ start, output.tail.start },
        &.{ count, output.tail.count },
    );
}

fn failure(err: anyerror) Lower.Error {
    return switch (err) {
        error.OutOfMemory, error.IntegerOverflow => error.OutOfMemory,
        else => unreachable,
    };
}
