const std = @import("std");
const view = @import("../node/view.zig");
const Lower = @import("lower.zig");
const Frame = @import("transform/execution.zig").Frame;

pub fn prepareTransformPredicate(handle: *const anyopaque) Lower.Error!void {
    const frame = Frame.borrow(handle);

    frame.label = try frame.lowering.fresh("predicate");
}

pub fn publishTransformPredicate(handle: *const anyopaque) Lower.Error!u32 {
    const frame = Frame.borrow(handle);
    const self = frame.lowering;
    const generated = @import("generated_predicate_emit");
    const Input = std.meta.Child(generated.Input);
    var scratch = std.heap.ArenaAllocator.init(self.workspace);

    defer scratch.deinit();

    const outer = try frame.body.block(self.allocator);
    const element_body = try frame.binding.block(self.allocator);

    const input = Input{
        .source = @backingInt(frame.source),
        .label = frame.label,
        .callback = @backingInt(frame.callback),
        .kind = switch (frame.transform.kind) {
            .every => .Every,
            .some => .Some,
            else => unreachable,
        },
        .capture = frame.capture,
        .outer_count = outer.len,
        .element_count = element_body.len,
        .expression_base = @intCast(self.builder.nodes.expressions.tags.items.len),
        .statement_base = @intCast(self.builder.nodes.statements.tags.items.len),
    };

    const output = generated.executeIn(scratch.allocator(), &input) catch |err| switch (err) {
        error.OutOfMemory, error.IntegerOverflow => return error.OutOfMemory,
        else => unreachable,
    };

    if (!output.valid) return error.OutOfMemory;

    const expressions = view.join(output.expressions.*, output.forms.*);

    try append(self, &self.builder.nodes.expressions, &expressions);

    try @import("transform/publication.zig").append(self, &.{
        .prelude = output.stop,
        .element = element_body,
        .step = output.decision,
        .outer = outer,
        .result = .{ .statements = output.main },
    });

    return output.root;
}

fn append(self: *Lower, target: anytype, source: anytype) Lower.Error!void {
    @import("../node/import_rows.zig").appendBorrowingText(self.allocator, target, source) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidAst => unreachable,
    };
}
