const std = @import("std");
const zx = @import("zx");
const node = @import("../../node.zig");
const view = @import("../../node/view.zig");
const Lower = @import("../lower.zig");
const emit = @import("emitting.zig");

pub fn complete(self: *Lower, type_id: zx.ir.TypeId, futures: []const []const u8, fields: []const ?u32, temporary: std.mem.Allocator) Lower.Error!emit.Started {
    const results = try temporary.alloc([]const u8, fields.len);
    const values = try temporary.alloc([]const u8, fields.len);
    const labels = @import("generated_task_parallel_labels");

    const names: std.meta.Child(labels.Input) = .{
        .serial = self.serial,
        .fields = fields,
        .results = @ptrCast(&results),
        .values = @ptrCast(&values),
    };

    self.serial = @intCast(zx.columns.invoke(labels.executeValue, self.allocator, &names) catch |err| return emit.failure(err));

    const entry = @import("generated_task_parallel_result");
    const Input = std.meta.Child(entry.Input);
    const output_type = self.program.typeOf(type_id);
    const bases = emit.context(std.meta.Child(@FieldType(Input, "bases")), self);

    const input: Input = .{
        .futures = futures,
        .results = results,
        .values = values,
        .fields = fields,
        .object_names = if (output_type == .object) output_type.object.names else null,
        .bases = &bases,
    };

    var buffer: [std.heap.page_size_min]u8 = undefined;
    var memory = std.heap.BufferFirstAllocator.init(&buffer, temporary);
    const compiled = entry.executeIn(memory.allocator(), &input) catch |err| return emit.failure(err);

    if (!compiled.valid) return error.OutOfMemory;

    const expressions = view.join(compiled.expressions.*, compiled.forms.*);

    try emit.append(self, &self.builder.nodes.expressions, &expressions);

    _ = @import("../../node/import_fields.zig").appendBorrowingText(self.allocator, &self.builder.nodes.field_columns, compiled.fields) catch |err| return emit.failure(err);

    const block = try self.builder.publishStatements(&.{}, compiled.statements);
    const root: node.ExpressionId = @fromBackingInt(compiled.root);
    const value = if (compiled.construct) try self.construct(type_id, root) else root;

    return .{ .block = block, .value = value };
}
