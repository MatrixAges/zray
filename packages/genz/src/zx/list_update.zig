const std = @import("std");
const ir = @import("zx").ir;
const node = @import("../node.zig");
const Lower = @import("lower.zig");
const aggregate = @import("aggregate.zig");
const lists = @import("state_value/list.zig");
const elements = @import("state_value/elements.zig");
const Sequence = @import("../node/blocks.zig").Sequence;

pub fn lower(self: *Lower, id: ir.ExprId) Lower.Error!node.ExpressionId {
    if (comptime !@import("genz_options").generated_analysis) return @import("list_update_seed.zig").lower(self, id);

    const update = self.program.expression(id).value.list_update;
    const type_id = self.program.expression(update.target).type_id;
    const selected = lists.selected(self, type_id);
    var body = self.builder.statementSequence(self.workspace);

    defer body.deinit();

    const evaluated = try self.expr(update.target);
    const qualified = if (selected) try @import("state_value/ownership.zig").clip(self, &body, update.target, evaluated) else evaluated;
    const target = try aggregate.bind(self, &body, qualified);
    const items = try lists.items(self, type_id, target);
    const index = try aggregate.bind(self, &body, try self.expr(update.index));

    try bounds(self, &body, items, index);

    const value = try elements.write(self, &body, type_id, try aggregate.bind(self, &body, try self.expr(update.value)));
    const element = try elements.typeExpr(self, type_id);
    const layout = if (selected) try @import("types.zig").get(self, self.state_types, type_id) else @as(node.ExpressionId, @fromBackingInt(0));
    const flags = self.plan.get(id);
    const entry = @import("generated_list_update");
    const Input = std.meta.Child(entry.Input);
    const Bases = std.meta.Child(@FieldType(Input, "bases"));
    var capture: Capture(Bases) = undefined;
    const bases = context(self, Bases, &capture);

    const input: Input = .{
        .bases = &bases,
        .items = @backingInt(items),
        .target = @backingInt(target),
        .index = @backingInt(index),
        .value = @backingInt(value),
        .element = @backingInt(element),
        .layout = @backingInt(layout),
        .selected = selected,
        .deferred = selected and self.deferred_lists,
        .in_place = flags.in_place,
        .grow = flags.grow,
        .exact = !self.may_grow,
        .shared = self.shared_types,
    };

    var scratch = std.heap.ArenaAllocator.init(self.workspace);

    defer scratch.deinit();

    var buffer: [std.heap.page_size_min]u8 = undefined;
    var memory = std.heap.BufferFirstAllocator.init(&buffer, scratch.allocator());
    const result = entry.executeIn(memory.allocator(), &input) catch |err| return failure(err);

    if (!result.valid) return error.OutOfMemory;
    try @import("construction/apply.zig").expressions(self, result);
    @import("../node/import_selected.zig").append(self.allocator, &self.builder.nodes.statements, result.statements) catch |err| return failure(err);

    var roots = result.statements.*;
    roots.tags = result.body.tags;
    roots.offsets = result.body.offsets;
    @import("../node/import_statements.zig").appendSelected(self.allocator, &body, &roots) catch |err| return failure(err);
    _ = @import("../node/import_fields.zig").appendBorrowingText(self.allocator, &self.builder.nodes.field_columns, result.fields) catch |err| return failure(err);
    self.serial = @intCast(result.serial);
    self.uses_allocator = self.uses_allocator or result.uses_allocator;

    return aggregate.finish(self, &body, @fromBackingInt(result.root));
}

fn bounds(self: *Lower, body: *Sequence, items: node.ExpressionId, index: node.ExpressionId) Lower.Error!void {
    const entry = @import("generated_list_update_bounds");
    const Input = std.meta.Child(entry.Input);
    const Bases = std.meta.Child(@FieldType(Input, "bases"));
    var capture: Capture(Bases) = undefined;
    const bases = context(self, Bases, &capture);
    const input: Input = .{ .bases = &bases, .items = @backingInt(items), .index = @backingInt(index) };
    var scratch = std.heap.ArenaAllocator.init(self.workspace);

    defer scratch.deinit();

    var buffer: [std.heap.page_size_min]u8 = undefined;
    var memory = std.heap.BufferFirstAllocator.init(&buffer, scratch.allocator());
    const result = entry.executeIn(memory.allocator(), &input) catch |err| return failure(err);

    try @import("intrinsics/guard.zig").publish(self, body, result);
}

fn Capture(comptime Bases: type) type {
    return std.meta.Child(@typeInfo(@FieldType(Bases, "capture")).optional.child);
}

fn context(self: *const Lower, comptime Bases: type, capture: *Capture(Bases)) Bases {
    return .{
        .capture = if (self.capture) |boundary| captured: {
            capture.* = .{ .name = boundary.name, .label = boundary.label, .failure = @backingInt(boundary.failure) };

            break :captured capture;
        } else null,
        .expression_base = @intCast(self.builder.nodes.expressions.tags.items.len),
        .statement_base = @intCast(self.builder.nodes.statements.tags.items.len),
        .field_base = @intCast(self.builder.nodes.field_columns.count()),
        .serial = self.serial,
    };
}

fn failure(err: anyerror) Lower.Error {
    return switch (err) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => error.OutOfMemory,
        else => unreachable,
    };
}
