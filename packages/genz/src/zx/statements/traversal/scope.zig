const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const node = @import("../../../node.zig");
const Lower = @import("../../lower.zig");
const emission = @import("../emit.zig");
const entry = @import("generated_statement_run_commit");
const Self = @This();

values: ir.Block,
starts: []u32,
counts: []u32,
routes: []const u8,
state_symbols: []const ir.SymbolId = &.{},
stack_symbols: []const ir.SymbolId = &.{},
condition: node.ExpressionId = undefined,
yes: node.Block = undefined,
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
    lowering.stack_symbols.removeMany(self.stack_symbols);
    lowering.state_symbols.removeMany(self.state_symbols);
}

pub fn run(self: *const Self, lowering: *Lower, output: *std.ArrayList(node.Statement), first: usize, count: usize) Lower.Error!void {
    var cursor = first + count;

    while (cursor > first) {
        const offset = cursor - 1;
        const result = try emission.emit(lowering, output, self.values, offset, self.routes[offset]);

        cursor = self.publish(cursor, result);
    }
}

pub fn put(self: *const Self, offset: usize, span: node.Block) void {
    _ = self.publish(offset + 1, .{ .span = span, .consumed_previous = false });
}

fn publish(self: *const Self, cursor: usize, result: emission.Output) usize {
    const input: std.meta.Child(entry.Input) = .{
        .starts = @ptrCast(&self.starts),
        .counts = @ptrCast(&self.counts),
        .cursor = cursor,
        .start = result.span.start,
        .count = result.span.len,
        .consumed_previous = result.consumed_previous,
    };

    var fixed = std.heap.FixedBufferAllocator.init(&.{});

    return @intCast(zx.columns.invoke(entry.executeValue, fixed.allocator(), &input) catch unreachable);
}

pub fn finish(self: *const Self, lowering: *Lower) Lower.Error!node.Block {
    if (self.values.len == 0) return .{};

    return @import("../../../node/blocks.zig").join(lowering.allocator, lowering.builder.nodes, self.starts, self.counts);
}
