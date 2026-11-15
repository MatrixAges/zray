const std = @import("std");
const zx = @import("zx");
const History = @import("../../history.zig");
const Signature = @import("../../signatures.zig").Signature;
const State = @import("../state.zig");
const rule = @import("generated_rx_mixed_history_reuse");
const Input = std.meta.Child(rule.Input);
const Pair = std.meta.Child(@typeInfo(@FieldType(Input, "signature")).optional.child);
const Columns = std.meta.Child(@FieldType(Pair, "left"));
const Source = std.meta.Child(@FieldType(Input, "source"));
const Extent = std.meta.Child(@FieldType(Input, "before"));

pub fn dependencyPrefix(state: *const State, redone: []const bool, first: usize, end: usize) usize {
    const prefix = @import("generated_rx_mixed_history_dependency_prefix");
    const graph = &state.graph;
    const edges = graph.source_dependencies.?;

    const input: std.meta.Child(prefix.Input) = .{
        .order = @ptrCast(graph.order),
        .first = first,
        .end = end,
        .entry = graph.entry,
        .compiled_dependencies = graph.modules.items(.compiled_dependency),
        .starts = edges.starts,
        .ends = edges.ends,
        .targets = edges.targets,
        .redone = redone,
    };

    var empty = std.heap.FixedBufferAllocator.init(&.{});
    const position = zx.columns.invoke(prefix.executeValue, empty.allocator(), &input) catch unreachable;

    return @intCast(position);
}

pub fn reusable(state: *const State, current: History.Frame, previous: *const History.Retained, redone: ?[]const bool, digests: []const ?[32]u8, index: usize, position: usize) bool {
    const current_source = state.graph.sources.at(index);
    const earlier = previous.derived.dependencies.sources.at(index);
    const before = extent(&previous.boundaries[position]);
    const after = extent(&previous.boundaries[position + 1]);
    var source: Source = .{ .store_equal = null, .previous_digest = null, .current_digest = null };
    var comparison: Pair = undefined;
    var left: Projected = undefined;
    var right: Projected = undefined;
    var a: Columns = undefined;
    var b: Columns = undefined;
    var signature: ?*const Pair = null;

    switch (current_source) {
        .store => |row| {
            source.store_equal = earlier == .store and @import("../../history/columns.zig").same(previous.derived.stores[earlier.store].node, current.stores[row].node);
        },
        else => {
            source.previous_digest = if (previous.digests[index] != null) &previous.digests[index].? else null;
            source.current_digest = if (digests[index] != null) &digests[index].? else null;

            if (current_source == .rx) {
                if (earlier != .rx) return false;

                left = .init(&previous.derived.resolved[earlier.rx]);
                right = .init(&current.resolved[current_source.rx]);
                a = left.view();
                b = right.view();
                comparison = .{ .left = &a, .right = &b, .masks = &.{} };
                signature = &comparison;
            }
        },
    }

    const edges = state.graph.source_dependencies.?;
    const Dependencies = std.meta.Child(@typeInfo(@FieldType(Input, "dependencies")).optional.child);

    const dependencies: Dependencies = if (redone) |marks| .{
        .dependencies = edges.targets,
        .redone = marks,
        .first = edges.starts[index],
        .end = edges.ends[index],
    } else undefined;

    const input: Input = .{
        .source = &source,
        .signature = signature,
        .compiled_dependency = redone != null and state.graph.modules.items(.compiled_dependency)[index],
        .dependencies = if (redone != null) &dependencies else null,
        .before = &before,
        .after = &after,
    };

    var empty = std.heap.FixedBufferAllocator.init(&.{});

    return zx.columns.invoke(rule.executeValue, empty.allocator(), &input) catch unreachable;
}

const Projected = struct {
    ports: [2]u32,
    words: [3][]const u8,
    names: [1][]const []const u8,
    fn init(signature: *const Signature) Projected {
        return .{
            .ports = .{ @backingInt(signature.input_type), @backingInt(signature.output_type) },
            .words = .{ undefined, std.mem.sliceAsBytes(signature.bindings.types), std.mem.sliceAsBytes(signature.tasks) },
            .names = .{signature.bindings.names},
        };
    }
    fn view(self: *Projected) Columns {
        self.words[0] = std.mem.asBytes(&self.ports);

        return .{ .words = &self.words, .tags = &.{}, .options = &.{}, .text = &self.names };
    }
};

fn extent(checkpoint: *const History.Checkpoint) Extent {
    return .{
        .native_modules = checkpoint.native_modules,
        .initializers = checkpoint.initializers,
        .libraries = checkpoint.libraries,
    };
}
