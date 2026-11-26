const std = @import("std");
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
        .writer = @ptrCast(self),
        .condition = @backingInt(check.condition),
        .expression_base = @intCast(self.builder.nodes.expressions.tags.items.len),
        .statement_base = @intCast(self.builder.nodes.statements.tags.items.len),
        .prefix_start = prefix.start,
        .body_start = body.start,
        .body_count = body.len,
        .prefix_count = prefix.len,
        .after_step = check.after_step,
        .guarded_initial = check.guarded_initial,
    };

    var scratch: std.heap.ArenaAllocator = .init(self.workspace);
    var buffer: [std.heap.page_size_min]u8 = undefined;
    var memory = std.heap.BufferFirstAllocator.init(&buffer, scratch.allocator());

    defer scratch.deinit();

    const output = module.executeIn(memory.allocator(), &input) catch |err| return failure(err);

    return .{ .start = output.start, .len = output.count };
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

fn failure(err: anyerror) Lower.Error {
    return switch (err) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => error.OutOfMemory,
        else => unreachable,
    };
}
