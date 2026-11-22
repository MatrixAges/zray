const std = @import("std");
const ir = @import("zx").ir;
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");
const blocks = @import("../../node/blocks.zig");

pub fn lower(self: *Lower, values: ir.Block) Lower.Error!node.Block {
    if (values.len == 0) return .{};

    const state_symbols = try @import("../state_value/locals.zig").statements(self, values);

    defer for (state_symbols) |symbol| {
        _ = self.state_symbols.remove(symbol);
    };

    const locals = @import("../value_call/locals.zig");
    const stacked = try locals.register(self, values);

    defer for (stacked) |symbol| {
        _ = self.stack_symbols.remove(symbol);
    };

    var inline_spans: [128 * 2]u32 = undefined;

    const spans = if (values.len <= inline_spans.len / 2)
        inline_spans[0 .. values.len * 2]

    else
        try self.workspace.alloc(u32, std.math.mul(usize, values.len, 2) catch return error.OutOfMemory);

    defer if (spans.len > inline_spans.len) self.workspace.free(spans);

    const starts = spans[0..values.len];
    const counts = spans[values.len..];
    var output: std.ArrayList(node.Statement) = .empty;

    defer output.deinit(self.allocator);

    var offset = values.len;

    while (offset > 0) {
        offset -= 1;

        const result = try emit(self, &output, values, offset);

        starts[offset] = result.span.start;
        counts[offset] = result.span.len;

        if (result.consumed_previous) {
            offset -= 1;
            starts[offset] = 0;
            counts[offset] = 0;
        }
    }

    return blocks.join(self.allocator, self.builder.nodes, starts, counts);
}

fn emit(self: *Lower, output: *std.ArrayList(node.Statement), values: ir.Block, offset: usize) Lower.Error!struct { span: node.Block, consumed_previous: bool } {
    const basic = @import("basic.zig");

    output.clearRetainingCapacity();

    var consumed_previous = false;
    const transaction = try @import("../store/begin.zig").lower(self, values, offset);

    const body = switch (values.at(offset)) {
        .evaluate => |id| try basic.discard(self, output, try @import("../iteration.zig").discard(self, id)),
        .parallel => |invocations| try @import("../parallel/root.zig").lower(self, invocations),
        .constant => |binding| bound: {
            const bind = @import("../binding.zig");

            if (bind.before(self, binding.value, binding.symbol, false) == .Task) {
                break :bound try @import("../tasks/root.zig").bind(self, self.names[@backingInt(binding.symbol)], binding.value, false);
            }

            const locals = @import("../value_call/locals.zig");
            const borrowed = try locals.optionalCall(self, output, binding.symbol, binding.value, self.program.output_type);
            const by_value = self.stack_symbols.contains(binding.symbol);
            const value = borrowed orelse if (by_value) try @import("../value_call/root.zig").expression(self, binding.value) else try self.expr(binding.value);

            break :bound try bind.publish(self, output, .{ .symbol = binding.symbol, .value = value, .by_value = by_value });
        },
        .destructure => |binding| try @import("destructure/lower.zig").publish(self, output, binding),
        .result => |value| result: {
            consumed_previous = try @import("result/seed.zig").append(self, output, values, offset, value);

            break :result try self.builder.statements(output.items);
        },
        .branch => |branch| conditional: {
            const condition = try self.expr(branch.condition);
            const yes = try lower(self, branch.yes);
            const no = try lower(self, branch.no);

            break :conditional try basic.branch(self, output, condition, yes, no);
        },
        .switch_stmt => |selection| try @import("switch/seed.zig").lowerSwitch(self, selection),
        .store_set => |setter| set: {
            const target = try basic.storeTarget(self, setter.slot);
            const value = try self.expr(setter.value);

            break :set try basic.assignment(self, output, target, value);
        },
    };

    const span = if (transaction.len == 0) body else try blocks.join(
        self.allocator,
        self.builder.nodes,
        &.{ transaction.start, body.start },
        &.{ transaction.len, body.len },
    );

    return .{ .span = span, .consumed_previous = consumed_previous };
}
