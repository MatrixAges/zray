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

        const result = try @import("emit.zig").emit(self, &output, values, offset, 0);

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
