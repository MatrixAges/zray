const std = @import("std");
const zx = @import("zx");
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");
const Operation = @FieldType(@FieldType(zx.ir.ExpressionRow, "value"), "conditional");
const generated = @import("genz_options").generated_analysis;

pub fn lower(self: *Lower, value: Operation) Lower.Error!node.ExpressionId {
    if (!generated) return construct(self, try self.expr(value.condition), try self.expr(value.yes), try self.expr(value.no));

    return evaluate(self, value, false);
}

pub fn lowerValue(self: *Lower, value: Operation) Lower.Error!node.ExpressionId {
    return evaluate(self, value, true);
}

fn evaluate(self: *Lower, value: Operation, comptime layout: bool) Lower.Error!node.ExpressionId {
    const plan = comptime blk: {
        var fixed = std.heap.FixedBufferAllocator.init(&.{});

        break :blk @import("generated_conditional_plan").executeValue(fixed.allocator(), layout) catch unreachable;
    };

    var condition: node.ExpressionId = undefined;
    var yes: node.ExpressionId = undefined;
    var no: node.ExpressionId = undefined;

    inline for (.{ plan.first, plan.second, plan.third }) |step| {
        switch (step) {
            .Condition => condition = try self.expr(value.condition),
            .Yes => yes = try self.expr(value.yes),
            .No => no = try self.expr(value.no),
            .ValueYes => yes = try @import("../value_call/root.zig").expression(self, value.yes),
            .ValueNo => no = try @import("../value_call/root.zig").expression(self, value.no),
        }
    }

    return construct(self, condition, yes, no);
}

pub fn construct(self: *Lower, condition: node.ExpressionId, yes: node.ExpressionId, no: node.ExpressionId) Lower.Error!node.ExpressionId {
    if (!generated) return self.builder.expression(.{ .conditional = .{ .condition = condition, .yes = yes, .no = no } });

    const entry = @import("generated_conditional_emit");
    const Input = std.meta.Child(entry.Input);
    const Output = std.meta.Child(entry.Output);
    const input: Input = .{ .condition = @backingInt(condition), .yes = @backingInt(yes), .no = @backingInt(no) };
    var buffer: [std.heap.page_size_min]u8 = undefined;
    var memory = std.heap.FixedBufferAllocator.init(&buffer);
    const output = try zx.columns.invoke(entry.executeValue, memory.allocator(), @as(*const Input, &input));
    const emitted = zx.columns.view(Output, output);
    const root = self.builder.nodes.expressions.tags.items.len;

    @import("../../node/import_rows.zig").appendBorrowed(self.allocator, &self.builder.nodes.expressions, &emitted) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidAst => unreachable,
    };

    return @fromBackingInt(@intCast(root));
}
