const std = @import("std");
const zx = @import("zx");
const Conditions = @import("../conditions.zig");
const terms = @import("../terms.zig");
const entry = @import("generated_merge_symbolic_returns");
const Store = std.meta.Child(@FieldType(entry.zx_pending, "store_0"));
const Selection = std.meta.Child(Store);
const span: zx.Span = .{ .start = 0, .end = 0 };

const Host = struct {
    conditions: *const Conditions,
    temporary: std.mem.Allocator,
    store_0: *Store,
    pub fn commit(host: *Host, pending: anytype) zx.Error!void {
        const state = pending.store_0 orelse return;
        const operation = state.operation.?;
        const conditions = host.conditions;
        const next = try host.temporary.create(Selection);
        next.* = state.*;
        next.operation = null;

        switch (operation.step) {
            .Select => {
                const returned = &conditions.returns.items[@intCast(operation.row.?)];
                const previous = terms.Evaluation.fromView(state.value).value;
                const selected = try conditions.graph.?.select(conditions.program, conditions.program.output_type, returned.path, returned.value, previous, span);
                next.value = try (terms.Evaluation{ .value = selected }).view(@TypeOf(next.value), host.temporary);
                next.term = returned.path;
            },
            .Boolean => next.term = try conditions.boolean(operation.term.?),
        }

        host.store_0.* = next;
    }
};

pub fn execute(conditions: *const Conditions) zx.Error!terms.Evaluation {
    const initial = conditions.returns.items[0].value;

    var store: Store = &.{
        .operation = null,
        .value = &.{ .text = initial.scalar, .fields = std.mem.sliceAsBytes(initial.fields), .safe = "true" },
        .term = "",
    };

    var effects = zx.Arena.initSmall(conditions.scratch.child);
    var buffer: [2048]u8 = undefined;
    var temporary = std.heap.BufferFirstAllocator.init(&buffer, effects.allocator());

    defer effects.deinit();

    var host: Host = .{ .conditions = conditions, .temporary = temporary.allocator(), .store_0 = &store };

    const input: std.meta.Child(entry.Input) = .{
        .returns = conditions.returns.items.len,
        .violations = conditions.violations,
    };

    const safe = entry.executeIn(conditions.allocator, &input, &host) catch |err| return @import("context.zig").failure(err);

    return .{ .value = terms.Evaluation.fromView(store.value).value, .safe = safe };
}
