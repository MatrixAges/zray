const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const node = @import("../../../node.zig");
const Lower = @import("../../lower.zig");
const rules = @import("rules.zig");

pub fn nested(self: *Lower, id: ir.ExprId) Lower.Error!?node.ExpressionId {
    const type_id = self.program.expression(id).type_id;

    if (!rules.raw(self, type_id, true)) return null;

    return lower(self, id);
}

pub fn anchor(self: *Lower, id: ir.ExprId) Lower.Error!node.ExpressionId {
    if (rules.value(self, id)) return @import("../../value_call/root.zig").expression(self, id);

    return self.expr(id);
}

pub fn lower(self: *Lower, id: ir.ExprId) Lower.Error!?node.ExpressionId {
    if (!@import("genz_options").generated_analysis) return @import("seed.zig").path(self, id);

    const entry = @import("generated_projection_path");
    const Input = std.meta.Child(entry.Input);
    const table = &self.program.expressions;
    const cache = self.cache.view(std.meta.Child(@FieldType(Input, "cache")));

    const input: Input = .{
        .kinds = zx.columns.slice(@FieldType(Input, "kinds"), table.kinds),
        .types = table.types,
        .payloads = table.payloads,
        .projection_targets = table.projection_targets,
        .projection_indices = table.projection_indices,
        .index_targets = table.index_targets,
        .index_values = table.index_values,
        .type_kinds = self.program.types.kinds,
        .type_first = self.program.types.first,
        .field_names = self.program.types.field_names,
        .queries = zx.columns.slice(@FieldType(Input, "queries"), self.state_plan.queries),
        .flags = std.mem.sliceAsBytes(self.plan.flags),
        .cache = &cache,
        .id = @backingInt(id),
    };

    var scratch = std.heap.ArenaAllocator.init(self.workspace);
    var buffer: [1024]u8 = undefined;
    var memory = std.heap.BufferFirstAllocator.init(&buffer, scratch.allocator());

    defer scratch.deinit();

    const plan = zx.columns.invoke(entry.executeValue, memory.allocator(), &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.Overflow, error.IntegerOverflow => return error.OutOfMemory,
        else => unreachable,
    };

    const base: ir.ExprId = @fromBackingInt(plan.anchor orelse return null);
    var value = if (plan.managed) try @import("../../state_value/list.zig").expression(self, base) else try anchor(self, base);
    var remaining: usize = @intCast(plan.key_count);
    var fields: usize = @intCast(plan.field_count);

    while (remaining != 0) {
        remaining -= 1;
        const boundary: usize = @intCast(plan.boundaries[remaining]);
        value = try @import("../emit.zig").fieldPath(self, value, plan.fields[boundary..fields]);
        value = try @import("../../intrinsics.zig").index(self, value, try self.expr(@fromBackingInt(plan.keys[remaining])));
        fields = boundary;
    }

    return try @import("../emit.zig").fieldPath(self, value, plan.fields[0..fields]);
}
