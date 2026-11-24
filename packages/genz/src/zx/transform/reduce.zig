const std = @import("std");
const ir = @import("zx").ir;
const node = @import("../../node.zig");
const view = @import("../../node/view.zig");
const Lower = @import("../lower.zig");
const elements = @import("../state_value/elements.zig");
const ownership = @import("../state_value/ownership.zig");
const blocks = @import("../../node/blocks.zig");
const Frame = @import("execution.zig").Frame;
const Statements = std.ArrayList(node.Statement);

pub const Request = struct {
    operation: ir.ExprId,
    transform: ir.Transform,
    source: node.ExpressionId,
    layout: node.ExpressionId,
    callback: node.ExpressionId,
};

pub fn lower(self: *Lower, body: *Statements, args: Request) Lower.Error!node.ExpressionId {
    const accumulator = self.names[@backingInt(args.transform.parameters[0])];
    const element = args.transform.parameters[1];
    const type_id = self.program.expression(args.operation).type_id;
    const source_type = self.program.expression(args.transform.target).type_id;
    const evaluated = try self.expr(args.transform.initial.?);
    const initial = if (self.state_active) try ownership.erase(self, body, type_id, evaluated) else evaluated;

    try body.append(self.allocator, .{ .variable = .{ .name = accumulator, .type_expr = args.layout, .value = initial } });

    const entered = try @import("../iteration/renewal_seed.zig").store(self, args.operation, type_id, .{ .name = accumulator });

    if (entered.len != 0) try body.append(self.allocator, .{ .branch = .{
        .condition = try self.builder.expression(.{ .binary = .{ .operator = .not_equal, .left = try self.field(args.source, "len"), .right = try self.builder.integer(0) } }),
        .yes = entered,
        .no = .{},
    } });

    var loop: Statements = .empty;
    const callback = if (self.state_active) try ownership.erase(self, &loop, type_id, args.callback) else args.callback;

    try loop.append(self.allocator, .{ .assignment = .{ .target = try self.builder.identifier(accumulator), .value = callback } });

    const result = try self.builder.identifier(accumulator);
    const capture = try elements.captureName(self, &loop, source_type, element);

    try body.append(self.allocator, .{ .for_loop = .{ .iterable = args.source, .capture = capture, .body = try self.builder.statements(loop.items) } });

    return @import("../aggregate.zig").finish(self, body, result);
}

pub fn lowerReduceInitial(handle: *const anyopaque) Lower.Error!void {
    const frame = Frame.borrow(handle);
    const self = frame.lowering;
    frame.name = self.names[@backingInt(frame.transform.parameters[0])];
    frame.initial = try self.expr(frame.transform.initial.?);
}

pub fn convertReduceInitial(handle: *const anyopaque) Lower.Error!void {
    const frame = Frame.borrow(handle);

    frame.initial = try ownership.erase(frame.lowering, &frame.body, frame.typeId(), frame.initial);
}

pub fn reduceInlineLists(handle: *const anyopaque) bool {
    const context = Frame.borrow(handle).lowering.iteration_value orelse return false;

    return context.inline_lists;
}

pub fn emitReduceRenewals(handle: *const anyopaque, first: u64, end: u64, filtered_inline: bool) Lower.Error!void {
    const frame = Frame.borrow(handle);

    frame.entered = try @import("../growth/renew.zig").entry(frame.lowering, .{
        .type_id = frame.typeId(),
        .target = .{ .name = frame.name },
        .first = @intCast(first),
        .end = @intCast(end),
        .skipped = frame.renewal_workspace.skipped.items,
        .filtered_inline = filtered_inline,
    });
}

pub fn convertReduceCallback(handle: *const anyopaque) Lower.Error!void {
    const frame = Frame.borrow(handle);

    frame.callback = try ownership.erase(frame.lowering, &frame.loop, frame.typeId(), frame.callback);
}

pub fn publishReduceTransform(handle: *const anyopaque) Lower.Error!u32 {
    const frame = Frame.borrow(handle);
    const self = frame.lowering;
    const label = try self.fresh("block");
    const outer_prefix = try frame.body.block(self.allocator);
    const callback_body = try frame.loop.block(self.allocator);
    const element_binding = try frame.binding.block(self.allocator);
    const nodes = self.builder.nodes;
    const element_body = try blocks.join(self.allocator, nodes, &.{ element_binding.start, callback_body.start }, &.{ element_binding.len, callback_body.len });
    const before = node.Block{ .start = element_body.start, .len = callback_body.len };
    const after = node.Block{ .start = before.start + before.len, .len = element_body.len - before.len };
    const entry = @import("generated_reduce_emit");
    const Input = std.meta.Child(entry.Input);

    const input: Input = .{
        .source = @backingInt(frame.source),
        .initial = @backingInt(frame.initial),
        .callback = @backingInt(frame.callback),
        .layout = @backingInt(frame.layout),
        .accumulator = frame.name,
        .capture = frame.capture,
        .label = label,
        .expression_base = @intCast(self.builder.nodes.expressions.tags.items.len),
        .statement_base = @intCast(self.builder.nodes.statements.tags.items.len),
        .entered_start = frame.entered.start,
        .entered_count = frame.entered.len,
        .element_start = element_body.start,
        .before_assignment = before.len,
        .element_count = element_body.len,
        .outer_count = outer_prefix.len,
    };

    var scratch = std.heap.ArenaAllocator.init(self.workspace);
    var buffer: [std.heap.page_size_min]u8 = undefined;
    var memory = std.heap.BufferFirstAllocator.init(&buffer, scratch.allocator());

    defer scratch.deinit();

    const output = entry.executeIn(memory.allocator(), &input) catch |err| return failure(err);

    if (!output.valid) return error.OutOfMemory;

    const outer = view.join(output.outer.*, output.variables.*);

    try append(self, &self.builder.nodes.expressions, output.expressions);

    try @import("publication.zig").append(self, &.{
        .element = before,
        .step = output.update,
        .remainder = after,
        .outer = outer_prefix,
        .result = .{ .reduce = &outer },
    });

    return output.root;
}

fn append(self: *Lower, target: anytype, source: anytype) Lower.Error!void {
    @import("../../node/import_rows.zig").appendBorrowed(self.allocator, target, source) catch |err| return failure(err);
}

fn failure(err: anyerror) Lower.Error {
    return switch (err) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => error.OutOfMemory,
        else => unreachable,
    };
}
