const std = @import("std");
const zx = @import("zx");
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");
const Form = enum { bind, block, guarded };
pub const Guard = struct { condition: node.ExpressionId, fallback: node.ExpressionId };

pub fn bind(self: *Lower, body: *std.ArrayList(node.Statement), value: node.ExpressionId) Lower.Error!node.ExpressionId {
    return lower(self, .bind, body, value, null);
}

pub fn finish(self: *Lower, body: node.Block, value: node.ExpressionId) Lower.Error!node.ExpressionId {
    return lower(self, .block, body, value, null);
}

pub fn finishGuarded(self: *Lower, body: node.Block, value: node.ExpressionId, guard: Guard) Lower.Error!node.ExpressionId {
    return lower(self, .guarded, body, value, guard);
}

fn lower(self: *Lower, comptime form: Form, body: if (form == .bind) *std.ArrayList(node.Statement) else node.Block, value: node.ExpressionId, guard: ?Guard) Lower.Error!node.ExpressionId {
    const generated = switch (form) {
        .bind => @import("generated_operand_binding"),
        .block => @import("generated_result_block"),
        .guarded => @import("generated_guarded_result_block"),
    };

    const Input = std.meta.Child(generated.Input);
    const Output = std.meta.Child(generated.Output);
    var input: Input = undefined;
    input.value = @backingInt(value);
    input.expression_base = @intCast(self.builder.nodes.expressions.tags.items.len);
    input.statement_base = if (form == .bind) 0 else body.start;
    input.body_count = if (form == .bind) 0 else body.len;
    input.serial = self.serial;

    if (form == .guarded) {
        input.condition = @backingInt(guard.?.condition);
        input.fallback = @backingInt(guard.?.fallback);
    }

    var scratch = std.heap.ArenaAllocator.init(self.workspace);
    var buffer: [std.heap.page_size_min]u8 = undefined;
    var buffered = std.heap.BufferFirstAllocator.init(&buffer, scratch.allocator());

    defer scratch.deinit();

    const output = zx.columns.invoke(generated.executeValue, buffered.allocator(), @as(*const Input, &input)) catch |err| return failure(err);

    if (!output.valid) return error.OutOfMemory;

    var expressions = zx.columns.view(std.meta.Child(@FieldType(Output, "expressions")), output.expressions);
    var statements = zx.columns.view(std.meta.Child(@FieldType(Output, "statements")), output.statements);
    const name = try self.allocator.dupe(u8, output.name);
    const names = [_][]const u8{name};

    if (form != .bind) {
        expressions.block_label = &names;
        statements.break_value_label = &names;
    } else {
        expressions.identifier = &names;
        statements.constant_name = &names;
    }

    if (form == .bind) {
        @import("../../node/import_statements.zig").appendBorrowingText(self.allocator, body, &statements) catch |err| return failure(err);
    } else {
        @import("../../node/import_rows.zig").appendBorrowed(self.allocator, &self.builder.nodes.statements, &statements) catch |err| return failure(err);
    }

    @import("../../node/import_rows.zig").appendBorrowed(self.allocator, &self.builder.nodes.expressions, &expressions) catch |err| return failure(err);

    self.serial = output.serial;

    return @fromBackingInt(output.root);
}

fn failure(err: anyerror) Lower.Error {
    return switch (err) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => error.OutOfMemory,
        else => unreachable,
    };
}
