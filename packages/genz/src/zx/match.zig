const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const node = @import("../node.zig");
const Lower = @import("lower.zig");
const aggregate = @import("aggregate.zig");

pub fn lower(self: *Lower, selection: ir.MatchRow) Lower.Error!node.ExpressionId {
    return lowerMode(self, selection, false);
}

pub fn lowerValue(self: *Lower, selection: ir.MatchRow) Lower.Error!node.ExpressionId {
    return lowerMode(self, selection, true);
}

fn lowerMode(self: *Lower, selection: ir.MatchRow, layout: bool) Lower.Error!node.ExpressionId {
    if (!@import("genz_options").generated_analysis) return if (layout) @import("match/seed.zig").lowerValue(self, selection) else @import("match/seed.zig").lower(self, selection);

    var body = self.builder.statementSequence(self.workspace);
    const previous = if (selection.subject) |id| self.cache.get(id) else null;

    defer body.deinit();

    defer if (selection.subject) |id| {
        if (self.cache.get(id) != previous) self.cache.restoreEntry(self.allocator, id, previous);
    };

    var scratch = std.heap.ArenaAllocator.init(self.workspace);
    var buffer: [std.heap.page_size_min]u8 = undefined;
    var buffered = std.heap.BufferFirstAllocator.init(&buffer, scratch.allocator());

    defer scratch.deinit();

    const allocator = buffered.allocator();
    const entry = @import("generated_lower_match_result");
    const Input = std.meta.Child(entry.Input);
    const Labels = std.meta.Child(@FieldType(Input, "source"));
    const Binary = std.meta.Child(@FieldType(Input, "binary_expressions"));
    const expressions = zx.columns.borrow(std.meta.Child(@FieldType(Labels, "expressions")), @as(*const ir.ExpressionTable, &self.program.expressions));
    const binary_expressions = zx.columns.borrow(Binary, @as(*const ir.ExpressionTable, &self.program.expressions));
    const types = ir.TypeTable.borrow(std.meta.Child(@FieldType(Labels, "types")), self.program.types);
    const nodes = self.builder.nodes;
    const positions: zx.memory.ColumnLengths = &.{ &nodes.expressions.tags.items.len, &nodes.arm_columns.fields.value.values.items.len };

    const labels: Labels = .{
        .expressions = &expressions,
        .types = &types,
        .subject = if (selection.subject) |id| @backingInt(id) else null,
        .conditions = selection.arms.conditions[0..selection.arms.len],
    };

    const input: Input = .{
        .frame = @ptrCast(self),
        .writer = @ptrCast(self),
        .binary_expressions = &binary_expressions,
        .body = @ptrCast(&body),
        .source = &labels,
        .results = selection.arms.results[0..selection.arms.len],
        .fallback = @backingInt(selection.fallback),
        .layout = layout,
        .positions = @ptrCast(&positions),
    };

    const output = zx.columns.invoke(entry.executeIn, allocator, &input) catch |err| return failure(err);

    if (!output.valid) return error.OutOfMemory;

    if (selection.arms.len != 0) {
        const Output = std.meta.Child(entry.Output);
        const arms = zx.columns.view(std.meta.Child(@FieldType(Output, "arms")), output.arms);
        const rows = zx.columns.view(std.meta.Child(@FieldType(Output, "nodes")), output.nodes);
        @import("../node/import_arms.zig").append(self.allocator, &nodes.arm_columns, &arms) catch |err| return failure(err);
        @import("../node/import_rows.zig").appendBorrowed(self.allocator, &nodes.expressions, &rows) catch |err| return failure(err);
    }

    const result: node.ExpressionId = @fromBackingInt(output.root);

    return if (selection.subject != null) aggregate.finish(self, &body, result) else result;
}

fn failure(err: anyerror) Lower.Error {
    return switch (err) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => error.OutOfMemory,
        else => unreachable,
    };
}
