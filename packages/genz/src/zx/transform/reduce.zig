const std = @import("std");
const ir = @import("zx").ir;
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");
const elements = @import("../state_value/elements.zig");
const ownership = @import("../state_value/ownership.zig");
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

pub fn emitReduceRenewals(handle: *anyopaque, accumulator: []const u8, first: u64, end: u64, filtered_inline: bool) Lower.Error!u64 {
    const frame = Frame.borrow(handle);

    return @import("../construction/publication.zig").packSpan(try @import("../growth/delivery.zig").entry(frame.lowering, .{
        .type_id = frame.typeId(),
        .target = .{ .name = accumulator },
        .first = @intCast(first),
        .end = @intCast(end),
        .skipped = frame.renewal_workspace.skipped.items,
        .filtered_inline = filtered_inline,
    }));
}

pub fn convertReduceValue(handle: *anyopaque, value: u32, initial: bool) Lower.Error!u32 {
    const frame = Frame.borrow(handle);
    const target = if (initial) &frame.body else &frame.loop;

    return @backingInt(try ownership.erase(frame.lowering, target, frame.typeId(), @fromBackingInt(value)));
}
