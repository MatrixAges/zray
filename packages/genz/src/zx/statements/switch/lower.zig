const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const node = @import("../../../node.zig");
const view = @import("../../../node/view.zig");
const rows = @import("../../../node/import_rows.zig");
const Lower = @import("../../lower.zig");
const services = @import("../../statements.zig");
const generated = @import("genz_options").generated_analysis;
const Selection = @FieldType(ir.StatementRow, "switch_stmt");

pub fn lower(self: *Lower, selection: Selection) Lower.Error!node.Block {
    if (!generated) return @import("seed.zig").lowerSwitch(self, selection);

    const entry = @import("generated_switch_emit");
    const Input = std.meta.Child(entry.Input);
    const Output = std.meta.Child(entry.Output);
    const Cases = std.meta.Child(@FieldType(Input, "cases"));
    const Bases = std.meta.Child(@FieldType(Input, "bases"));
    const name = try @import("references.zig").name(self);
    const subject = try self.expr(selection.subject);
    const old = self.cache.get(selection.subject);
    const reference = try @import("references.zig").identifier(self, name);

    try self.cache.put(self.allocator, selection.subject, reference);

    defer {
        if (old) |previous| self.cache.put(self.allocator, selection.subject, previous) catch unreachable else _ = self.cache.remove(selection.subject);
    }

    var scratch = std.heap.ArenaAllocator.init(self.workspace);
    var buffer: [std.heap.page_size_min]u8 = undefined;
    var buffered = std.heap.BufferFirstAllocator.init(&buffer, scratch.allocator());

    defer scratch.deinit();

    const allocator = buffered.allocator();
    const positions = try allocator.alloc(u32, std.math.mul(usize, selection.cases.len, 2) catch return error.OutOfMemory);
    const labels = positions[0..selection.cases.len];
    const rows_by_case = positions[selection.cases.len..];
    const named = try partition(selection.cases, labels, rows_by_case);
    var fallback: ?node.Block = null;
    var default_cursor = selection.cases.len;

    while (default_cursor > named) {
        default_cursor -= 1;
        const item = selection.cases.at(rows_by_case[default_cursor]);
        fallback = try services.lower(self, item.body);
    }

    const selected = try @import("../../selection.zig").labels(self, selection.subject, labels[0..named]);
    const starts = try allocator.alloc(u32, named);
    const counts = try allocator.alloc(u32, named);
    const comparisons = try allocator.alloc(u32, named);
    const literals = try allocator.alloc(?u32, named);
    var remaining = named;

    while (remaining != 0) {
        remaining -= 1;
        const item = selection.cases.at(rows_by_case[remaining]);
        const label: ir.ExprId = @fromBackingInt(labels[remaining]);
        comparisons[remaining] = 0;
        literals[remaining] = null;

        if (!selected) comparisons[remaining] = @backingInt(try self.binary(.{ .operator = .equal, .left = selection.subject, .right = label }));

        const body = try services.lower(self, item.body);

        starts[remaining] = body.start;
        counts[remaining] = body.len;

        if (selected) {
            if (remaining + 1 == named) {
                comparisons[remaining] = @backingInt(try self.binary(.{ .operator = .equal, .left = selection.subject, .right = label }));
            } else {
                literals[remaining] = @backingInt(try @import("../../selection.zig").literal(self, label));
            }
        }
    }

    const cases: Cases = .{ .body_start = starts, .body_count = counts, .conditions = comparisons, .literals = literals };

    const bases: Bases = .{
        .capture = null,
        .expression_base = @intCast(self.builder.nodes.expressions.tags.items.len),
        .statement_base = @intCast(self.builder.nodes.statements.tags.items.len),
        .field_base = @intCast(self.builder.nodes.field_columns.count()),
        .serial = self.serial,
    };

    const input: Input = .{
        .name = name,
        .subject = @backingInt(subject),
        .reference = @backingInt(reference),
        .selected = selected,
        .exhaustive = selection.exhaustive,
        .total_count = selection.cases.len,
        .fallback_start = if (fallback) |block| block.start else null,
        .fallback_count = if (fallback) |block| block.len else 0,
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

fn partition(cases: @FieldType(Selection, "cases"), labels: []u32, rows_by_case: []u32) Lower.Error!usize {
    const entry = @import("generated_switch_partition");

    const input: std.meta.Child(entry.Input) = .{
        .values = cases.values[0..cases.len],
        .labels = @ptrCast(&labels),
        .rows = @ptrCast(&rows_by_case),
    };

    var empty = std.heap.FixedBufferAllocator.init(&.{});
    const result = zx.columns.invoke(entry.executeValue, empty.allocator(), &input) catch |err| return failure(err);

    return @intCast(result);
}

fn failure(err: anyerror) Lower.Error {
    return switch (err) {
        error.OutOfMemory, error.IntegerOverflow => error.OutOfMemory,
        else => unreachable,
    };
}
