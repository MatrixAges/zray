const std = @import("std");
const zx = @import("zx");
const node = @import("../../../node.zig");
const rows = @import("../../../node/import_rows.zig");
const Lower = @import("../../lower.zig");
const Sequence = @import("../../../node/blocks.zig").Sequence;

pub fn emit(self: *Lower, sequence: *Sequence, value: ?node.ExpressionId) Lower.Error!node.Block {
    const entry = @import("generated_result_emit");
    const Input = std.meta.Child(entry.Input);
    const Output = std.meta.Child(entry.Output);
    const Bases = std.meta.Child(@FieldType(Input, "bases"));
    const Expressions = std.meta.Child(@typeInfo(@FieldType(Output, "expressions")).optional.child);

    const bases: Bases = .{
        .capture = if (self.capture) |capture| &.{ .name = capture.name, .label = capture.label, .failure = @backingInt(capture.failure) } else null,
        .expression_base = @intCast(self.builder.nodes.expressions.tags.items.len),
        .statement_base = @intCast(self.builder.nodes.statements.tags.items.len),
        .field_base = @intCast(self.builder.nodes.field_columns.count()),
        .serial = self.serial,
    };

    const input: Input = .{ .value = if (value) |id| @backingInt(id) else null, .transaction = self.transaction(), .bases = &bases };
    var scratch = std.heap.ArenaAllocator.init(self.workspace);
    var buffer: [std.heap.page_size_min]u8 = undefined;
    var memory = std.heap.BufferFirstAllocator.init(&buffer, scratch.allocator());

    defer scratch.deinit();

    const allocator = memory.allocator();
    const result = entry.executeIn(allocator, &input) catch |err| return failure(err);

    if (!result.valid) return error.OutOfMemory;

    const name = if (result.name) |text| try self.allocator.dupe(u8, text) else null;
    var body = zx.columns.view(std.meta.Child(@FieldType(Output, "statements")), result.statements);

    if (result.expressions) |emitted| {
        var expressions = zx.columns.view(Expressions, emitted);

        if (name) |text| {
            const identifiers = try allocator.dupe(std.meta.Child(@FieldType(Expressions, "identifier")), expressions.identifier);

            identifiers[0] = text;
            expressions.identifier = identifiers;
        }

        rows.appendBorrowingText(self.allocator, &self.builder.nodes.expressions, &expressions) catch |err| return failure(err);
    }

    if (name) |text| {
        const names = try allocator.dupe(std.meta.Child(@TypeOf(body.constant_name)), body.constant_name);

        names[0] = text;
        body.constant_name = names;
    }

    @import("../../../node/import_statements.zig").appendBorrowingText(self.allocator, sequence, &body) catch |err| return failure(err);
    self.serial = @intCast(result.serial);

    return sequence.finish(self.allocator);
}

fn failure(err: anyerror) Lower.Error {
    return switch (err) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => error.OutOfMemory,
        else => unreachable,
    };
}
