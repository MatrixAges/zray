const std = @import("std");
const ir = @import("zx").ir;
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");
const elements = @import("../state_value/elements.zig");
const ownership = @import("../state_value/ownership.zig");
const Sequence = @import("../../node/blocks.zig").Sequence;
const borrow = @import("../expressions/evaluate.zig").borrow;
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

pub fn emitReduceRenewals(frame: *anyopaque, result_type: u32, accumulator: []const u8, first: u64, end: u64, skipped: []const u64, filtered_inline: bool) Lower.Error!u64 {
    return @import("../construction/publication.zig").packSpan(try @import("../growth/delivery.zig").entry(borrow(frame), .{
        .type_id = @fromBackingInt(result_type),
        .target = .{ .name = accumulator },
        .first = @intCast(first),
        .end = @intCast(end),
        .skipped = skipped,
        .filtered_inline = filtered_inline,
    }));
}

pub fn convertReduceValue(frame: *anyopaque, sequence: *anyopaque, result_type: u32, value: u32) Lower.Error!u32 {
    const target: *Sequence = @ptrCast(@alignCast(sequence));

    return @backingInt(try ownership.erase(borrow(frame), target, @fromBackingInt(result_type), @fromBackingInt(value)));
}
