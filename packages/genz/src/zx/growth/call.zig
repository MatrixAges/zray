const std = @import("std");
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");
const Sequence = @import("../../node/blocks.zig").Sequence;
const generated = @import("generated_growth_call");
const Input = std.meta.Child(generated.Input);

const Request = struct {
    element: node.ExpressionId,
    value: node.ExpressionId,
    flag: bool = false,
};

pub fn prepare(self: *const Lower, operation: @FieldType(Input, "operation"), request: Request) Input {
    return .{
        .operation = operation,
        .element = @backingInt(request.element),
        .value = @backingInt(request.value),
        .count = 0,
        .minimum = 0,
        .flag = request.flag,
        .shared = self.shared_types,
        .capture = null,
        .expression_base = @intCast(self.builder.nodes.expressions.tags.items.len),
        .statement_base = @intCast(self.builder.nodes.statements.tags.items.len),
        .serial = self.serial,
    };
}

pub fn normalize(self: *Lower, body: *Sequence, element: node.ExpressionId, value: node.ExpressionId, selected: bool, layout: ?node.ExpressionId) Lower.Error!node.ExpressionId {
    const entry = @import("generated_growth_normalize");
    const Parameter = std.meta.Child(entry.Input);
    var scratch = std.heap.ArenaAllocator.init(self.workspace);
    var buffer: [std.heap.page_size_min]u8 = undefined;
    var buffered = std.heap.BufferFirstAllocator.init(&buffer, scratch.allocator());

    defer scratch.deinit();

    var source = prepare(self, .Reserve, .{ .element = element, .value = value });
    const Capture = std.meta.Child(@typeInfo(@FieldType(Input, "capture")).optional.child);
    var boundary: Capture = undefined;

    if (self.capture) |capture| {
        boundary = .{ .name = capture.name, .label = capture.label, .failure = @backingInt(capture.failure) };
        source.capture = &boundary;
    }

    const input: Parameter = .{
        .source = &source,
        .selected = selected,
        .layout = if (layout) |expression| @backingInt(expression) else 0,
        .field_base = @intCast(self.builder.nodes.field_columns.count()),
    };

    const emitted = entry.executeIn(buffered.allocator(), &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => return error.OutOfMemory,
        else => unreachable,
    };

    return publish(self, body, emitted);
}

pub fn publish(self: *Lower, body: ?*Sequence, emitted: anytype) Lower.Error!node.ExpressionId {
    const wrapped = @hasField(std.meta.Child(@TypeOf(emitted)), "result");
    const output = if (wrapped) emitted.result else emitted;

    if (!output.valid) return error.OutOfMemory;

    const apply = @import("../construction/apply.zig");

    try apply.expressions(self, output);
    try apply.rows(self, &self.builder.nodes.statements, output.statements);

    if (body) |target| {
        @import("../../node/import_statements.zig").append(self.allocator, target, output.body) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidAst => unreachable,
        };
    } else {
        try apply.rows(self, &self.builder.nodes.statements, output.body);
    }

    if (wrapped) {
        _ = @import("../../node/import_fields.zig").appendBorrowingText(self.allocator, &self.builder.nodes.field_columns, emitted.fields) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidAst => unreachable,
        };
    }

    self.serial = @intCast(output.serial);
    self.uses_allocator = self.uses_allocator or output.uses_allocator;

    return @fromBackingInt(output.root);
}
