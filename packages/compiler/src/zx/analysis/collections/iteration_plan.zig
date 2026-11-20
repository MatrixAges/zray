const std = @import("std");
const zx = @import("zx");
const generated = @import("parser_options").generated_parser;
const entry = if (generated) @import("generated_collection_iteration_plan") else struct {};
pub const Kind = @FieldType(zx.ir.Transform, "kind");

pub const Plan = if (generated) std.meta.Child(entry.Output) else struct {
    initial: enum { Empty, True, False, Given, First },
    condition: enum { Bound, WhileTrue, WhileFalse },
    update: enum { Append, Filter, Replace },
    accumulator: bool,
    result: enum { Value, Source, Unit, SourceAndValue, ValueAndUnit },
};

pub fn choose(kind: Kind, has_initial: bool, tuple_result: bool, projection: ?u64) Plan {
    if (!generated) return seed(kind, has_initial, tuple_result, projection);

    const input: std.meta.Child(entry.Input) = .{
        .kind = @fromBackingInt(@intCast(@backingInt(kind))),
        .has_initial = has_initial,
        .tuple_result = tuple_result,
        .projection = projection,
    };

    var empty = std.heap.FixedBufferAllocator.init(&.{});
    const plan = zx.columns.invoke(entry.executeValue, empty.allocator(), &input) catch unreachable;

    return .{
        .initial = plan.initial,
        .condition = plan.condition,
        .update = plan.update,
        .accumulator = plan.accumulator,
        .result = plan.result,
    };
}

fn seed(kind: Kind, has_initial: bool, tuple_result: bool, projection: ?u64) Plan {
    return .{
        .initial = switch (kind) {
            .sort => unreachable,
            .map, .filter => .Empty,
            .every => .True,
            .some => .False,
            .reduce => if (has_initial) .Given else .First,
        },
        .condition = switch (kind) {
            .every => .WhileTrue,
            .some => .WhileFalse,
            else => .Bound,
        },
        .update = switch (kind) {
            .map => .Append,
            .filter => .Filter,
            else => .Replace,
        },
        .accumulator = kind == .reduce,
        .result = if (!tuple_result) .Value else if (projection) |slot|
            if (kind == .reduce) (if (slot == 0) .Source else .Value) else (if (slot == 1) .Unit else .Value)
        else if (kind == .reduce) .SourceAndValue else .ValueAndUnit,
    };
}
