const std = @import("std");
const zx = @import("zx");
const History = @import("../../history.zig");
const Reuse = @import("../reuse.zig");
const State = @import("../state.zig");
const alignment = @import("alignment.zig");
const compare = @import("frontend").compare_ir;
const link_columns = @import("link_columns.zig");
const snapshot = @import("snapshot.zig");

pub fn analyzed(reuse: *Reuse, state: *State, owner: *History.History, index: usize, position: usize) std.mem.Allocator.Error!void {
    const rule = @import("generated_rx_mixed_history_record");
    const Input = std.meta.Child(rule.Input);
    const Analysis = std.meta.Child(@typeInfo(@FieldType(Input, "analysis")).optional.child);
    const before = &reuse.boundaries[position];
    const after = &reuse.boundaries[position + 1];
    var storage: snapshot.Storage = undefined;
    const capture = storage.bind(state);
    var borrowed: alignment.Borrowed = undefined;
    var types: std.meta.Child(@FieldType(Analysis, "alignment")) = undefined;
    var edges_input: std.meta.Child(@FieldType(Analysis, "dependencies")) = undefined;
    var functions_input: std.meta.Child(@FieldType(Analysis, "functions")) = undefined;
    const Comparison = std.meta.Child(@typeInfo(@FieldType(Analysis, "comparison")).optional.child);
    const Link = std.meta.Child(@FieldType(Comparison, "link"));
    const Range = std.meta.Child(@FieldType(Comparison, "functions"));
    var comparison_input: Comparison = undefined;
    var columns: link_columns.Columns(Link) = undefined;
    var link: Link = undefined;
    var functions: Range = undefined;
    const prior = if (reuse.aligned) reuse.previous else null;

    const analysis: Analysis = if (prior) |previous| block: {
        const earlier = previous.boundaries[position..][0..2];
        const edges = state.graph.source_dependencies.?;

        types = borrowed.project(state, previous, before, &earlier[1], &storage.extent);

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

        if (functions_input.linked) {
            link = columns.bind(&state.finished, &previous.finished, index);
            functions = compare.range(Range, &previous.functions, &state.functions, before.functions, @intCast(storage.extent.functions));
            comparison_input = .{ .link = &link, .functions = &functions };
        }

        break :block .{
            .alignment = &types,
            .compiled_dependency = state.graph.modules.items(.compiled_dependency)[index],
            .dependencies = &edges_input,
            .functions = &functions_input,
            .comparison = if (functions_input.linked) &comparison_input else null,
        };
    } else undefined;

    const input: Input = .{
        .capture = &capture,
        .target = &.{
            .analyzed = owner.analyzed,
            .aligned = reuse.aligned,
        },
        .analysis = if (prior != null) &analysis else null,
    };

    var arena = std.heap.ArenaAllocator.init(state.scratch.child_allocator);

    defer arena.deinit();

    var buffer: [1024]u8 = undefined;
    var scratch = std.heap.BufferFirstAllocator.init(&buffer, arena.allocator());

    const result = zx.columns.invoke(rule.executeValue, scratch.allocator(), &input) catch |err| switch (err) {
        error.OutOfMemory, error.Overflow => return error.OutOfMemory,
        else => unreachable,
    };

    snapshot.commit(after, result.checkpoint);

    const recorded = result.recorded;
    owner.analyzed = @intCast(recorded.analyzed);
    reuse.redone[index] = recorded.redone;
    reuse.aligned = recorded.aligned;
}
