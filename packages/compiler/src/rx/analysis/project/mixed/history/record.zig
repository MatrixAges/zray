const std = @import("std");
const zx = @import("zx");
const History = @import("../../history.zig");
const Reuse = @import("../reuse.zig");
const State = @import("../state.zig");
const alignment = @import("alignment.zig");
const comparison = @import("comparison.zig");

pub fn analyzed(reuse: *Reuse, state: *const State, owner: *History.History, index: usize, position: usize) void {
    const rule = @import("generated_rx_mixed_history_record");
    const Input = std.meta.Child(rule.Input);
    const Analysis = std.meta.Child(@typeInfo(@FieldType(Input, "analysis")).optional.child);
    const before = &reuse.boundaries[position];
    const after = &reuse.boundaries[position + 1];

    @import("snapshot.zig").write(state, after);

    const aligned: []bool = @as(*[1]bool, @ptrCast(&reuse.aligned));

    const counter: zx.memory.WriteColumn = .{
        .items = @ptrCast(&owner.analyzed),
        .count = 1,
        .stride = @sizeOf(usize),
        .width = @sizeOf(usize),
    };

    var borrowed: alignment.Borrowed = undefined;
    var types: std.meta.Child(@FieldType(Analysis, "alignment")) = undefined;
    var edges_input: std.meta.Child(@FieldType(Analysis, "dependencies")) = undefined;
    var functions_input: std.meta.Child(@FieldType(Analysis, "functions")) = undefined;
    var comparison_input: std.meta.Child(@FieldType(Analysis, "comparison")) = undefined;
    var link: comparison.Link = undefined;
    var functions: comparison.Range = undefined;
    const prior = if (reuse.aligned) reuse.previous else null;

    const analysis: Analysis = if (prior) |previous| block: {
        const earlier = previous.boundaries[position..][0..2];
        const edges = state.graph.source_dependencies.?;

        types = borrowed.project(state, previous, before, &earlier[1], after);

        edges_input = .{
            .dependencies = edges.targets,
            .redone = reuse.redone,
            .first = edges.starts[index],
            .end = edges.ends[index],
        };

        functions_input = .{
            .first = before.functions,
            .previous_first = earlier[0].functions,
            .linked = state.finished.present[index] and previous.finished.present[index],
            .store = state.graph.sources.at(index) == .store,
        };

        link = .{ .earlier = &previous.finished, .current = &state.finished, .row = index };

        functions = .{
            .earlier = &previous.functions,
            .current = &state.functions,
            .first = before.functions,
            .end = after.functions,
        };

        comparison_input = .{ .link = @ptrCast(&link), .functions = @ptrCast(&functions) };

        break :block .{
            .alignment = &types,
            .compiled_dependency = state.graph.modules.items(.compiled_dependency)[index],
            .dependencies = &edges_input,
            .functions = &functions_input,
            .comparison = &comparison_input,
        };
    } else undefined;

    const input: Input = .{
        .target = &.{
            .row = index,
            .analyzed = owner.analyzed,
            .counter = @ptrCast(&counter),
            .redone = @ptrCast(&reuse.redone),
            .aligned = @ptrCast(&aligned),
        },
        .analysis = if (prior != null) &analysis else null,
    };

    var scratch = std.heap.FixedBufferAllocator.init(&.{});

    zx.columns.invoke(rule.executeValue, scratch.allocator(), &input) catch unreachable;
}
