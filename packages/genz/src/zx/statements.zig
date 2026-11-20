const std = @import("std");
const ir = @import("zx").ir;
const node = @import("../node.zig");
const Lower = @import("lower.zig");
const emission = @import("statements/basic.zig");
const planning = @import("statements/block.zig");
const blocks = @import("../node/blocks.zig");
const generated = @import("genz_options").generated_analysis;

pub fn lower(self: *Lower, values: ir.Block) Lower.Error!node.Block {
    if (values.len == 0) return .{};

    const state_symbols = try @import("state_value/locals.zig").statements(self, values);

    defer for (state_symbols) |symbol| {
        _ = self.state_symbols.remove(symbol);
    };

    const locals = @import("value_call/locals.zig");
    const stacked = try locals.register(self, values);

    defer for (stacked) |symbol| {
        _ = self.stack_symbols.remove(symbol);
    };

    var inline_routes: [128]u8 = undefined;

    const routes = if (generated)
        if (values.len <= inline_routes.len) inline_routes[0..values.len] else try self.workspace.alloc(u8, values.len)

    else
        &.{};

    defer if (routes.len > inline_routes.len) self.workspace.free(routes);

    if (generated) try planning.fill(self, values, routes);

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

        output.clearRetainingCapacity();

        var consumed_previous = false;
        const route = if (generated) routes[offset] else 0;

        const transaction = if (if (generated) route & planning.flags.store_route != 0 else true)
            try @import("store/begin.zig").lower(self, values, offset)
        else
            node.Block{};

        const body = switch (values.at(offset)) {
            .evaluate => |id| try emission.discard(self, &output, try @import("iteration.zig").discard(self, id)),
            .parallel => |invocations| try @import("parallel/root.zig").lower(self, invocations),
            .constant => |binding| binding_block: {
                const task = if (generated) route & planning.flags.task_route != 0 else @import("binding.zig").before(self, binding.value, binding.symbol, false) == .Task;

                if (task) break :binding_block try @import("tasks/root.zig").bind(self, self.names[@backingInt(binding.symbol)], binding.value, false);

                var sequence = self.builder.statementSequence(self.workspace);

                defer if (generated) sequence.deinit();

                const local = if (generated) &sequence else &output;
                const borrowed = try locals.optionalCall(self, local, binding.symbol, binding.value, self.program.output_type);
                const value = borrowed orelse if (self.stack_symbols.contains(binding.symbol)) try @import("value_call/root.zig").expression(self, binding.value) else try self.expr(binding.value);

                break :binding_block try @import("binding.zig").publish(self, local, .{
                    .symbol = binding.symbol,
                    .value = value,
                    .by_value = self.stack_symbols.contains(binding.symbol),
                });
            },
            .destructure => |binding| try @import("statements/destructure/lower.zig").publish(self, &output, binding),
            .result => |value| result: {
                const fuse = if (generated) route & planning.flags.fuse_route != 0 else false;
                const lowered = try @import("statements/result/lower.zig").publish(self, &output, values, offset, value, fuse);

                consumed_previous = lowered.consumed_previous;

                break :result lowered.block;
            },
            .branch => |branch| conditional: {
                const condition = try self.expr(branch.condition);
                const yes = try lower(self, branch.yes);
                const no = try lower(self, branch.no);

                break :conditional try emission.branch(self, &output, condition, yes, no);
            },
            .switch_stmt => |selection| try @import("statements/switch/lower.zig").lower(self, selection),
            .store_set => |setter| store_set: {
                const target = try emission.storeTarget(self, setter.slot);
                const value = try self.expr(setter.value);

                break :store_set try emission.assignment(self, &output, target, value);
            },
        };

        const span = if (transaction.len == 0) body else try blocks.join(
            self.allocator,
            self.builder.nodes,
            &.{ transaction.start, body.start },
            &.{ transaction.len, body.len },
        );

        starts[offset] = span.start;
        counts[offset] = span.len;

        if (consumed_previous) {
            offset -= 1;
            starts[offset] = 0;
            counts[offset] = 0;
        }
    }

    return blocks.join(self.allocator, self.builder.nodes, starts, counts);
}

pub const writes = @import("control/writes.zig").writes;
