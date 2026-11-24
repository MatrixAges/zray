const std = @import("std");
const columns = @import("zx").columns;
const Lower = @import("../lower.zig");
const Sequence = @import("../../node/blocks.zig").Sequence;
const apply = @import("../construction/apply.zig");
const entry = @import("generated_publish_growth_ast");
const generation = @import("generated_growth_delivery");
const Delivery = std.meta.Child(@typeInfo(@typeInfo(@TypeOf(generation.executeValue)).@"fn".return_type.?).error_union.payload);
const Growth = std.meta.Child(@FieldType(std.meta.Child(std.meta.Child(generation.Output)), "result"));

const Frame = struct {
    lower: *Lower,
    body: ?*Sequence,
    output: *const Delivery,
    fn borrow(target: *const anyopaque) *const Frame {
        return @ptrCast(@alignCast(target));
    }
};

pub fn publish(self: *Lower, body: ?*Sequence, output: *const Delivery) Lower.Error!void {
    const frame: Frame = .{ .lower = self, .body = body, .output = output };

    const input: std.meta.Child(entry.Input) = .{
        .target = @ptrCast(&frame),
        .sequence = body != null,
        .fields = output.fields != null,
        .serial = output.result.serial,
        .uses_allocator = output.uses_allocator,
    };

    var fixed = std.heap.FixedBufferAllocator.init(&.{});

    return entry.executeIn(fixed.allocator(), &input);
}

pub fn appendGrowthExpressions(target: *const anyopaque) Lower.Error!void {
    const frame = Frame.borrow(target);
    const output = &frame.output.result;
    const expressions = columns.view(std.meta.Child(@FieldType(Growth, "expressions")), output.expressions);
    const forms = columns.view(std.meta.Child(@FieldType(Growth, "forms")), output.forms);

    try apply.expressions(frame.lower, .{ .expressions = &expressions, .forms = &forms });
}

pub fn appendGrowthStatements(target: *const anyopaque) Lower.Error!void {
    const frame = Frame.borrow(target);

    try apply.rows(frame.lower, &frame.lower.builder.nodes.statements, frame.output.result.statements);
}

pub fn appendGrowthSequence(target: *const anyopaque) Lower.Error!void {
    const frame = Frame.borrow(target);
    const statements = @import("../../node/import_statements.zig");

    statements.append(frame.lower.allocator, frame.body.?, frame.output.result.body) catch |err| return imported(err);
}

pub fn appendGrowthBody(target: *const anyopaque) Lower.Error!void {
    const frame = Frame.borrow(target);

    try apply.rows(frame.lower, &frame.lower.builder.nodes.statements, frame.output.result.body);
}

pub fn appendGrowthFields(target: *const anyopaque) Lower.Error!void {
    const frame = Frame.borrow(target);
    const fields = @import("../../node/import_fields.zig");
    _ = fields.appendBorrowingText(frame.lower.allocator, &frame.lower.builder.nodes.field_columns, frame.output.fields.?) catch |err| return imported(err);
}

pub fn commitGrowthPublication(target: *const anyopaque, serial: u64, uses_allocator: bool) void {
    const frame = Frame.borrow(target);

    frame.lower.serial = @intCast(serial);
    frame.lower.uses_allocator = uses_allocator;
}

fn imported(err: @import("../../node/import_rows.zig").Error) Lower.Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidAst => unreachable,
    };
}
