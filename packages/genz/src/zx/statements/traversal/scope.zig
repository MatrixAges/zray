const std = @import("std");
const ir = @import("zx").ir;
const node = @import("../../../node.zig");
const Lower = @import("../../lower.zig");
const Selection = @import("../switch/state.zig");
const Self = @This();

values: ir.Block,
starts: []u32,
counts: []u32,
routes: []const u8,
state_symbols: []const ir.SymbolId = &.{},
stack_symbols: []const ir.SymbolId = &.{},
condition: node.ExpressionId = undefined,
yes: node.Block = undefined,
selection: ?*Selection = null,
pub const Buffer = struct {
    starts: []u32,
    counts: []u32,
    routes: []u8,
};

pub fn open(lowering: *Lower, values: ir.Block, buffer: Buffer) Lower.Error!Self {
    var scope: Self = .{ .values = values, .starts = buffer.starts, .counts = buffer.counts, .routes = buffer.routes };

    if (values.len == 0) return scope;

    scope.state_symbols = try @import("../../state_value/locals.zig").statements(lowering, values);

    errdefer lowering.state_symbols.removeMany(scope.state_symbols);

    scope.stack_symbols = try @import("../../value_call/locals.zig").register(lowering, values);

    errdefer lowering.stack_symbols.removeMany(scope.stack_symbols);

    try @import("../block.zig").fill(lowering, values, buffer.routes);

    return scope;
}

pub fn close(self: *const Self, lowering: *Lower) void {
    if (self.selection) |selection| selection.leave(lowering);

    lowering.stack_symbols.removeMany(self.stack_symbols);
    lowering.state_symbols.removeMany(self.state_symbols);
}

pub fn run(self: *const Self, lowering: *Lower, output: *std.ArrayList(node.Statement), first: usize, count: usize) Lower.Error!void {
    var offset = first + count;

    while (offset > first) {
        offset -= 1;

        const result = try @import("../emit.zig").emit(lowering, output, self.values, offset, self.routes[offset]);

        self.put(offset, result.span);

        if (result.consumed_previous) {
            offset -= 1;

            self.put(offset, .{});
        }
    }
}

pub fn put(self: *const Self, offset: usize, span: node.Block) void {
    self.starts[offset] = span.start;
    self.counts[offset] = span.len;
}

pub fn finish(self: *const Self, lowering: *Lower) Lower.Error!node.Block {
    if (self.values.len == 0) return .{};

    return @import("../../../node/blocks.zig").join(lowering.allocator, lowering.builder.nodes, self.starts, self.counts);
}
