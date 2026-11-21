const std = @import("std");
const ir = @import("zx").ir;
const node = @import("../node.zig");
const Lower = @import("lower.zig");
const aggregate = @import("aggregate.zig");
const bridge = @import("match/bridge.zig");

pub fn lower(self: *Lower, selection: ir.MatchRow) Lower.Error!node.ExpressionId {
    return lowerMode(self, selection, false);
}

pub fn lowerValue(self: *Lower, selection: ir.MatchRow) Lower.Error!node.ExpressionId {
    return lowerMode(self, selection, true);
}

fn lowerMode(self: *Lower, selection: ir.MatchRow, layout: bool) Lower.Error!node.ExpressionId {
    if (!@import("genz_options").generated_analysis) return if (layout) @import("match/seed.zig").lowerValue(self, selection) else @import("match/seed.zig").lower(self, selection);

    const prepared = bridge.prepare(selection, layout);
    const subject: ?ir.ExprId = if (prepared.subject) |id| @fromBackingInt(id) else null;
    const previous = if (subject) |id| self.cache.get(id) else null;
    var body: std.ArrayList(node.Statement) = .empty;

    defer body.deinit(self.allocator);

    const binding: ?node.ExpressionId = if (subject) |id| binding: {
        const saved = try aggregate.bind(self, &body, try self.expr(id));

        try self.cache.put(self.allocator, id, saved);

        break :binding saved;
    } else null;

    defer if (subject) |id| self.cache.restoreEntry(self.allocator, id, previous);

    if (prepared.discard) try body.append(self.allocator, .{ .discard = binding.? });

    const fallback = try evaluate(self, prepared.result, prepared.fallback, 0);
    const result = if (prepared.has_arms) try lowerArms(self, selection, prepared.result, fallback) else fallback;

    return if (subject == null) result else aggregate.finish(self, &body, result);
}

fn lowerArms(self: *Lower, selection: ir.MatchRow, mode: bridge.ResultMode, fallback: node.ExpressionId) Lower.Error!node.ExpressionId {
    var scratch = std.heap.ArenaAllocator.init(self.workspace);
    var buffer: [std.heap.page_size_min]u8 = undefined;
    var buffered = std.heap.BufferFirstAllocator.init(&buffer, scratch.allocator());

    defer scratch.deinit();

    const allocator = buffered.allocator();
    const plan = try bridge.plan(self, allocator, selection, mode);

    if (!plan.valid) return error.OutOfMemory;

    const values = try allocator.alloc(node.ExpressionId, plan.operations.len);

    for (plan.operations, plan.first, plan.second, values) |operation, first, second, *value| {
        value.* = try evaluate(self, operation, first, second);
    }

    return bridge.emit(self, allocator, plan.selected, plan.count, values, fallback);
}

fn evaluate(self: *Lower, operation: anytype, first: u32, second: u32) Lower.Error!node.ExpressionId {
    const id: ir.ExprId = @fromBackingInt(first);

    return switch (operation) {
        .Expression => self.expr(id),
        .Value => @import("value_call/root.zig").expression(self, id),
        .Equality => self.binary(.{ .operator = .equal, .left = id, .right = @fromBackingInt(second) }),
        .Literal => @import("selection.zig").literal(self, id),
    };
}
