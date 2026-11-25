const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");
const Sequence = @import("../../node/blocks.zig").Sequence;

pub const Prepared = struct { name: []const u8, label: []const u8, value: node.ExpressionId, is_void: bool };

pub fn prepare(self: *Lower, payload: ir.TypeId) Lower.Error!Prepared {
    const entry = @import("generated_capture_prepare");
    const Input = std.meta.Child(entry.Input);
    const Output = std.meta.Child(entry.Output);

    const input: Input = .{
        .serial = self.serial,
        .payload_kind = self.program.types.kinds[@backingInt(payload)],
        .payload_scalar = self.program.types.first[@backingInt(payload)],
        .expression_base = @intCast(self.builder.nodes.expressions.tags.items.len),
    };

    var scratch = std.heap.ArenaAllocator.init(self.workspace);
    var buffer: [std.heap.page_size_min]u8 = undefined;
    var memory = std.heap.BufferFirstAllocator.init(&buffer, scratch.allocator());

    defer scratch.deinit();

    const output = zx.columns.invoke(entry.executeValue, memory.allocator(), &input) catch |err| return failure(err);

    if (!output.valid) return error.OutOfMemory;

    const name = try self.allocator.dupe(u8, output.name);
    const label = try self.allocator.dupe(u8, output.label);
    self.serial = @intCast(output.serial);
    const rows = zx.columns.view(std.meta.Child(@FieldType(Output, "nodes")), output.nodes);
    @import("../../node/import_rows.zig").append(self.allocator, &self.builder.nodes.expressions, &rows) catch |err| return failure(err);

    return .{ .name = name, .label = label, .value = @fromBackingInt(output.root), .is_void = output.is_void };
}

pub fn result(self: *Lower, body: *Sequence, value: node.ExpressionId, type_expr: node.ExpressionId, is_void: bool) Lower.Error!node.ExpressionId {
    const entry = @import("generated_capture_result");
    const Input = std.meta.Child(entry.Input);
    const Output = std.meta.Child(entry.Output);

    const input: Input = .{
        .value = @backingInt(value),
        .type_expr = @backingInt(type_expr),
        .is_void = is_void,
        .expression_base = @intCast(self.builder.nodes.expressions.tags.items.len),
    };

    var scratch = std.heap.ArenaAllocator.init(self.workspace);
    var buffer: [std.heap.page_size_min]u8 = undefined;
    var memory = std.heap.BufferFirstAllocator.init(&buffer, scratch.allocator());

    defer scratch.deinit();

    const output = zx.columns.invoke(entry.executeValue, memory.allocator(), &input) catch |err| return failure(err);

    if (!output.valid) return error.OutOfMemory;

    const rows = zx.columns.view(std.meta.Child(@FieldType(Output, "nodes")), output.nodes);
    const statements = zx.columns.view(std.meta.Child(@FieldType(Output, "statements")), output.statements);
    @import("../../node/import_statements.zig").appendBorrowingText(self.allocator, body, &statements) catch |err| return failure(err);
    @import("../../node/import_rows.zig").appendBorrowingText(self.allocator, &self.builder.nodes.expressions, &rows) catch |err| return failure(err);

    return @fromBackingInt(output.root);
}

pub fn finish(self: *Lower, body: *Sequence, value: node.ExpressionId, layout: node.ExpressionId, label: []const u8) Lower.Error!node.ExpressionId {
    const entry = @import("generated_capture_finish");
    const Input = std.meta.Child(entry.Input);
    const Output = std.meta.Child(entry.Output);
    const prefix = try body.finish(self.allocator);

    const input: Input = .{
        .value = @backingInt(value),
        .layout = @backingInt(layout),
        .label = label,
        .expression_base = @intCast(self.builder.nodes.expressions.tags.items.len),
        .statement_base = prefix.start,
        .body_count = prefix.len,
    };

    var scratch = std.heap.ArenaAllocator.init(self.workspace);
    var buffer: [std.heap.page_size_min]u8 = undefined;
    var memory = std.heap.BufferFirstAllocator.init(&buffer, scratch.allocator());

    defer scratch.deinit();

    const output = zx.columns.invoke(entry.executeValue, memory.allocator(), &input) catch |err| return failure(err);

    if (!output.valid) return error.OutOfMemory;

    const rows = zx.columns.view(std.meta.Child(@FieldType(Output, "nodes")), output.nodes);
    const statements = zx.columns.view(std.meta.Child(@FieldType(Output, "statements")), output.statements);
    @import("../../node/import_rows.zig").appendBorrowingText(self.allocator, &self.builder.nodes.statements, &statements) catch |err| return failure(err);
    @import("../../node/import_rows.zig").appendBorrowingText(self.allocator, &self.builder.nodes.expressions, &rows) catch |err| return failure(err);

    return @fromBackingInt(output.root);
}

fn failure(err: anyerror) Lower.Error {
    return switch (err) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => error.OutOfMemory,
        else => unreachable,
    };
}
