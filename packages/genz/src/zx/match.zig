const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const node = @import("../node.zig");
const Lower = @import("lower.zig");
const aggregate = @import("aggregate.zig");
const evaluation = @import("expressions/evaluate.zig");
const bridge = @import("match/bridge.zig");
const Sequence = @import("../node/blocks.zig").Sequence;

pub fn lower(self: *Lower, selection: ir.MatchRow) Lower.Error!node.ExpressionId {
    return lowerMode(self, selection, false);
}

pub fn lowerValue(self: *Lower, selection: ir.MatchRow) Lower.Error!node.ExpressionId {
    return lowerMode(self, selection, true);
}

const Frame = struct {
    lowering: *Lower,
    selection: ir.MatchRow,
    mode: bridge.ResultMode,
    subject: ?ir.ExprId,
    previous: ?node.ExpressionId,
    body: Sequence,
    installed: bool = false,
    fn borrow(handle: *const anyopaque) *Frame {
        return @ptrCast(@alignCast(@constCast(handle)));
    }
    fn restore(self: *Frame) void {
        if (self.installed) self.lowering.cache.restoreEntry(self.lowering.allocator, self.subject.?, self.previous);

        self.body.deinit();
    }
};

fn lowerMode(self: *Lower, selection: ir.MatchRow, layout: bool) Lower.Error!node.ExpressionId {
    if (!@import("genz_options").generated_analysis) return if (layout) @import("match/seed.zig").lowerValue(self, selection) else @import("match/seed.zig").lower(self, selection);

    const prepared = bridge.prepare(selection, layout);
    const subject: ?ir.ExprId = if (prepared.subject) |id| @fromBackingInt(id) else null;

    var frame: Frame = .{
        .lowering = self,
        .selection = selection,
        .mode = prepared.result,
        .subject = subject,
        .previous = if (subject) |id| self.cache.get(id) else null,
        .body = self.builder.statementSequence(self.workspace),
    };

    defer frame.restore();

    const entry = @import("generated_lower_match_result");

    const input: std.meta.Child(entry.Input) = .{
        .frame = @ptrCast(self),
        .selection = @ptrCast(&frame),
        .subject = prepared.subject,
        .discard = prepared.discard,
        .fallback = prepared.fallback,
        .value = prepared.result == .Value,
        .has_arms = prepared.has_arms,
    };

    return evaluation.invoke(entry, &input);
}

pub fn publishMatchSubject(handle: *const anyopaque, value: u32, discard: bool) Lower.Error!void {
    const frame = Frame.borrow(handle);
    const self = frame.lowering;
    const binding = try aggregate.bind(self, &frame.body, @fromBackingInt(value));

    try self.cache.put(self.allocator, frame.subject.?, binding);

    frame.installed = true;

    if (discard) try frame.body.append(try self.builder.statements(&.{.{ .discard = binding }}));
}

pub fn lowerMatchArms(handle: *const anyopaque, fallback: u32) Lower.Error!u32 {
    const frame = Frame.borrow(handle);

    return @backingInt(try lowerArms(frame.lowering, frame.selection, frame.mode, @fromBackingInt(fallback)));
}

pub fn finishMatchResult(handle: *const anyopaque, value: u32) Lower.Error!u32 {
    const frame = Frame.borrow(handle);

    return @backingInt(try aggregate.finish(frame.lowering, &frame.body, @fromBackingInt(value)));
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
