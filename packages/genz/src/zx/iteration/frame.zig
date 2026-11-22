const std = @import("std");
const zx = @import("zx");
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");

pub const Check = struct {
    condition: node.ExpressionId,
    after_step: bool,
    guarded_initial: bool = false,
};

pub fn lower(
    self: *Lower,
    prefix: node.Block,
    body: node.Block,
    check: Check,
) Lower.Error!node.Block {
    const nodes = self.builder.nodes;

    std.debug.assert(@as(usize, body.start) + body.len == nodes.statements.tags.items.len);

    if (!@import("genz_options").generated_analysis) return seed(self, prefix, body, check);

    const module = @import("generated_iteration_frame");
    const Input = std.meta.Child(module.Input);

    const input: Input = .{
        .condition = @backingInt(check.condition),
        .expression_base = @intCast(self.builder.nodes.expressions.tags.items.len),
        .statement_base = @intCast(self.builder.nodes.statements.tags.items.len),
        .body_start = body.start,
        .body_count = body.len,
        .prefix_count = prefix.len,
        .after_step = check.after_step,
        .guarded_initial = check.guarded_initial,
    };

    var buffer: [std.heap.page_size_min]u8 = undefined;
    var memory = std.heap.FixedBufferAllocator.init(&buffer);
    const output = zx.columns.invoke(module.executeValue, memory.allocator(), &input) catch |err| return failure(err);

    if (!output.valid) return error.OutOfMemory;

    const frame: Publication = .{ .lowering = self, .prefix = prefix, .output = &output };
    const publish = @import("generated_publish_loop_frame");

    const publication: std.meta.Child(publish.Input) = .{
        .target = @ptrCast(&frame),
        .guarded = output.guard != null,
        .entry = output.entry != null,
    };

    try @import("../expressions/evaluate.zig").execute(publish, &publication);

    return .{ .start = output.start, .len = output.count };
}

const frame_entry = @import("generated_iteration_frame");
const FrameOutput = std.meta.Child(frame_entry.Output);
const FrameValue = @typeInfo(@typeInfo(@TypeOf(frame_entry.executeValue)).@"fn".return_type.?).error_union.payload;

const Publication = struct {
    lowering: *Lower,
    prefix: node.Block,
    output: *const FrameValue,
    fn borrow(handle: *const anyopaque) *const Publication {
        return @ptrCast(@alignCast(handle));
    }
};

pub fn appendLoopGuard(handle: *const anyopaque) Lower.Error!void {
    const frame = Publication.borrow(handle);
    const self = frame.lowering;
    const nodes = self.builder.nodes;
    const guard = frame.output.guard.?;
    const Guard = std.meta.Child(@typeInfo(@FieldType(FrameOutput, "guard")).optional.child);
    const expressions = zx.columns.view(std.meta.Child(@FieldType(Guard, "expressions")), guard.expressions);
    const exit = zx.columns.view(std.meta.Child(@FieldType(Guard, "exit")), guard.exit);
    const stop = zx.columns.view(std.meta.Child(@FieldType(Guard, "stop")), guard.stop);

    try appendRows(self, &nodes.expressions, &expressions);
    try appendRows(self, &nodes.statements, &exit);
    try appendRows(self, &nodes.statements, &stop);
}

pub fn appendLoopPrefix(handle: *const anyopaque) Lower.Error!void {
    const frame = Publication.borrow(handle);
    const self = frame.lowering;

    _ = try @import("../../node/blocks.zig").tail(self.allocator, self.builder.nodes, &.{frame.prefix.start}, &.{frame.prefix.len});
}

pub fn appendLoopBody(handle: *const anyopaque) Lower.Error!void {
    const frame = Publication.borrow(handle);
    const body = zx.columns.view(std.meta.Child(@FieldType(FrameOutput, "statement")), frame.output.statement);

    try appendRows(frame.lowering, &frame.lowering.builder.nodes.statements, &body);
}

pub fn appendLoopEntry(handle: *const anyopaque) Lower.Error!void {
    const frame = Publication.borrow(handle);
    const Branch = std.meta.Child(@typeInfo(@FieldType(FrameOutput, "entry")).optional.child);
    const branch = zx.columns.view(Branch, frame.output.entry.?);

    try appendRows(frame.lowering, &frame.lowering.builder.nodes.statements, &branch);
}

fn seed(self: *Lower, prefix: node.Block, body: node.Block, check: Check) Lower.Error!node.Block {
    const renewed = prefix.len != 0;
    const trailing = check.after_step or renewed or check.guarded_initial;
    var statements = body;
    var condition = check.condition;

    if (trailing) {
        const stop = std.math.cast(u32, self.builder.nodes.statements.tags.items.len + 1) orelse return error.OutOfMemory;
        const exit = try self.builder.expression(.{ .unary = .{ .operator = .not, .operand = check.condition } });

        _ = try self.builder.statements(&.{.{ .branch = .{
            .condition = exit,
            .yes = .{ .start = stop, .len = 1 },
            .no = .{},
        } }});

        _ = try self.builder.statements(&.{.break_loop});
        statements.len += 1;
        condition = try self.builder.expression(.{ .boolean = true });
    }

    var entered = try @import("../../node/blocks.zig").tail(self.allocator, self.builder.nodes, &.{prefix.start}, &.{prefix.len});

    _ = try self.builder.statements(&.{.{ .while_loop = .{ .condition = condition, .body = statements } }});
    entered.len += 1;

    if (!check.after_step and renewed) return self.builder.statements(&.{.{ .branch = .{
        .condition = check.condition,
        .yes = entered,
        .no = .{},
    } }});

    return entered;
}

fn appendRows(self: *Lower, target: anytype, source: anytype) Lower.Error!void {
    @import("../../node/import_rows.zig").appendBorrowed(self.allocator, target, source) catch |err| return failure(err);
}

fn failure(err: anyerror) Lower.Error {
    return switch (err) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => error.OutOfMemory,
        else => unreachable,
    };
}
