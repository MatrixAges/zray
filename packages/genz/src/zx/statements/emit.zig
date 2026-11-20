const std = @import("std");
const ir = @import("zx").ir;
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");
const emission = @import("basic.zig");
const planning = @import("block.zig");
const blocks = @import("../../node/blocks.zig");
const generated = @import("genz_options").generated_analysis;

pub const Output = struct { span: node.Block, consumed_previous: bool };

pub fn emit(self: *Lower, output: *std.ArrayList(node.Statement), values: ir.Block, offset: usize, route: u8) Lower.Error!Output {
    const locals = @import("../value_call/locals.zig");

    output.clearRetainingCapacity();

    var consumed_previous = false;

    const transaction = if (if (generated) route & planning.flags.store_route != 0 else true)
        try @import("../store/begin.zig").lower(self, values, offset)
    else
        node.Block{};

    const body = switch (values.at(offset)) {
        .evaluate => |id| try emission.discard(self, output, try @import("../iteration.zig").discard(self, id)),
        .parallel => |invocations| try @import("../parallel/root.zig").lower(self, invocations),
        .constant => |binding| binding_block: {
            const task = if (generated) route & planning.flags.task_route != 0 else @import("../binding.zig").before(self, binding.value, binding.symbol, false) == .Task;

            if (task) break :binding_block try @import("../tasks/root.zig").bind(self, self.names[@backingInt(binding.symbol)], binding.value, false);

            var sequence = self.builder.statementSequence(self.workspace);

            defer if (generated) sequence.deinit();

            const local = if (generated) &sequence else output;
            const borrowed = try locals.optionalCall(self, local, binding.symbol, binding.value, self.program.output_type);
            const value = borrowed orelse if (self.stack_symbols.contains(binding.symbol)) try @import("../value_call/root.zig").expression(self, binding.value) else try self.expr(binding.value);

            break :binding_block try @import("../binding.zig").publish(self, local, .{
                .symbol = binding.symbol,
                .value = value,
                .by_value = self.stack_symbols.contains(binding.symbol),
            });
        },
        .destructure => |binding| try @import("destructure/lower.zig").publish(self, output, binding),
        .result => |value| result: {
            const fuse = if (generated) route & planning.flags.fuse_route != 0 else false;
            const lowered = try @import("result/lower.zig").publish(self, output, values, offset, value, fuse);

            consumed_previous = lowered.consumed_previous;

            break :result lowered.block;
        },
        .branch => |branch| conditional: {
            if (generated) unreachable;

            const condition = try self.expr(branch.condition);
            const seed = @import("seed.zig");
            const yes = try seed.lower(self, branch.yes);
            const no = try seed.lower(self, branch.no);

            break :conditional try emission.branch(self, output, condition, yes, no);
        },
        .switch_stmt => |selection| conditional: {
            if (generated) unreachable;

            break :conditional try @import("switch/seed.zig").lowerSwitch(self, selection);
        },
        .store_set => |setter| store_set: {
            const target = try emission.storeTarget(self, setter.slot);
            const value = try self.expr(setter.value);

            break :store_set try emission.assignment(self, output, target, value);
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
