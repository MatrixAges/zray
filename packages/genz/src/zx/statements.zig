const std = @import("std");
const ir = @import("zx").ir;
const node = @import("../node.zig");
const Lower = @import("lower.zig");
const emission = @import("statements/basic.zig");
const planning = @import("statements/block.zig");
const generated = @import("genz_options").generated_analysis;

pub fn lower(self: *Lower, values: ir.Block) Lower.Error![]const node.Statement {
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

    const chunks = try self.allocator.alloc([]const node.Statement, values.len);
    var offset = values.len;
    var total: usize = 0;

    while (offset > 0) {
        offset -= 1;
        var output: std.ArrayList(node.Statement) = .empty;
        var consumed_previous = false;
        const route = if (generated) routes[offset] else 0;

        if (if (generated) route & planning.flags.store_route != 0 else true) {
            if (try @import("store/begin.zig").statement(self, values, offset)) |begin| try output.append(self.allocator, begin);
        }

        switch (values.at(offset)) {
            .evaluate => |id| try emission.discard(self, &output, try @import("iteration.zig").discard(self, id)),
            .parallel => |invocations| try output.appendSlice(self.allocator, try @import("parallel/root.zig").lower(self, invocations)),
            .constant => |binding| binding_block: {
                const task = if (generated) route & planning.flags.task_route != 0 else @import("binding.zig").before(self, binding.value, binding.symbol, false) == .Task;

                if (task) {
                    try @import("tasks/root.zig").bind(self, &output, self.names[@backingInt(binding.symbol)], binding.value, false);

                    break :binding_block;
                }

                const borrowed = try locals.optionalCall(self, &output, binding.symbol, binding.value, self.program.output_type);
                const value = borrowed orelse if (self.stack_symbols.contains(binding.symbol)) try @import("value_call/root.zig").expression(self, binding.value) else try self.expr(binding.value);

                try @import("binding.zig").append(self, &output, .{
                    .symbol = binding.symbol,
                    .value = value,
                    .by_value = self.stack_symbols.contains(binding.symbol),
                });
            },
            .destructure => |binding| try @import("statements/destructure/lower.zig").append(self, &output, binding),
            .result => |value| {
                const fuse = if (generated) route & planning.flags.fuse_route != 0 else false;

                consumed_previous = try @import("statements/result/lower.zig").append(self, &output, values, offset, value, fuse);
            },
            .branch => |branch| {
                const condition = try self.expr(branch.condition);
                const yes = try self.builder.statements(try lower(self, branch.yes));
                const no = try self.builder.statements(try lower(self, branch.no));

                try emission.branch(self, &output, condition, yes, no);
            },
            .switch_stmt => |selection| try output.appendSlice(self.allocator, try switchStatement(self, selection)),
            .store_set => |setter| {
                const target = try emission.storeTarget(self, setter.slot);
                const value = try self.expr(setter.value);

                try emission.assignment(self, &output, target, value);
            },
        }

        const chunk = try output.toOwnedSlice(self.allocator);

        total = std.math.add(usize, total, chunk.len) catch return error.OutOfMemory;
        chunks[offset] = chunk;

        if (consumed_previous) {
            offset -= 1;
            chunks[offset] = &.{};
        }
    }

    const output = try self.allocator.alloc(node.Statement, total);
    var position: usize = 0;

    for (chunks) |chunk| {
        @memcpy(output[position..][0..chunk.len], chunk);

        position += chunk.len;
    }

    return output;
}

fn switchStatement(self: *Lower, selection: @FieldType(ir.StatementRow, "switch_stmt")) Lower.Error![]const node.Statement {
    return @import("statements/switch/lower.zig").lower(self, selection);
}

pub const writes = @import("control/writes.zig").writes;
