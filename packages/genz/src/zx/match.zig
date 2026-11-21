const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const node = @import("../node.zig");
const Lower = @import("lower.zig");
const aggregate = @import("aggregate.zig");
const evaluation = @import("expressions/evaluate.zig");
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

    const fallback_id: ir.ExprId = @fromBackingInt(prepared.fallback);
    const fallback = if (prepared.result == .Value) try @import("value_call/root.zig").expression(self, fallback_id) else try self.expr(fallback_id);
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
    const entry = @import("generated_lower_match_arms");
    const Input = std.meta.Child(entry.Input);
    const storage: []u32 = @ptrCast(values);

    const input: Input = .{
        .frame = @ptrCast(self),
        .operations = zx.columns.slice(@FieldType(Input, "operations"), plan.operations),
        .first = plan.first,
        .second = plan.second,
        .values = @ptrCast(&storage),
    };

    try evaluation.execute(entry, &input);

    return bridge.emit(self, allocator, plan.selected, plan.count, values, fallback);
}

pub fn lowerMatchEquality(handle: *const anyopaque, left: u32, right: u32) Lower.Error!u32 {
    return @backingInt(try evaluation.borrow(handle).binary(.{ .operator = .equal, .left = @fromBackingInt(left), .right = @fromBackingInt(right) }));
}

pub fn lowerMatchLiteral(handle: *const anyopaque, id: u32) Lower.Error!u32 {
    return @backingInt(try @import("selection.zig").literal(evaluation.borrow(handle), @fromBackingInt(id)));
}
