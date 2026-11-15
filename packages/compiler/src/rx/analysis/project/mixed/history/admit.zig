const std = @import("std");
const zx = @import("zx");
const History = @import("../../history.zig");
const Signature = @import("../../signatures.zig").Signature;
const State = @import("../state.zig");
const rule = @import("generated_rx_mixed_history_reuse");
const Input = std.meta.Child(rule.Input);
const Extent = std.meta.Child(@FieldType(Input, "before"));
const prefix = @import("generated_rx_mixed_history_prefix");
const Prefix = std.meta.Child(prefix.Input);
const PrefixResult = @typeInfo(@TypeOf(prefix.executeValue(undefined, undefined))).error_union.payload;
pub const ScanHistory = std.meta.Child(@FieldType(Prefix, "history"));

pub const Borrowed = struct {
    dependencies: std.meta.Child(@FieldType(ScanHistory, "dependencies")),
    earlier: std.meta.Child(@FieldType(ScanHistory, "earlier")),
    current: std.meta.Child(@FieldType(ScanHistory, "current")),
    boundaries: std.meta.Child(@FieldType(ScanHistory, "boundaries")),
    pub fn init(state: *const State, previous: *const History.Retained, digests: History.SourceDigests, redone: []const bool) Borrowed {
        const graph = &state.graph;
        const edges = graph.source_dependencies.?;
        const word = @sizeOf(u64);

        comptime {
            const Checkpoint = History.Checkpoint;
            const offset = @offsetOf(Checkpoint, "native_modules");

            if (@offsetOf(Checkpoint, "initializers") != offset + word or @offsetOf(Checkpoint, "libraries") != offset + 2 * word) @compileError("mixed history link counters must be adjacent native words");
        }

        return .{
            .dependencies = .{
                .compiled = graph.modules.items(.compiled_dependency),
                .starts = edges.starts,
                .ends = edges.ends,
                .targets = edges.targets,
                .redone = redone,
            },
            .earlier = .{
                .words = std.mem.bytesAsSlice(u64, std.mem.sliceAsBytes(previous.digests.words)),
                .present = previous.digests.present,
            },
            .current = .{
                .words = std.mem.bytesAsSlice(u64, std.mem.sliceAsBytes(digests.words)),
                .present = digests.present,
            },
            .boundaries = .{
                .words = std.mem.bytesAsSlice(u64, std.mem.sliceAsBytes(previous.boundaries)),
                .stride = @sizeOf(History.Checkpoint) / word,
                .links_offset = @offsetOf(History.Checkpoint, "native_modules") / word,
            },
        };
    }

    pub fn view(self: *const Borrowed) ScanHistory {
        return .{
            .dependencies = &self.dependencies,
            .earlier = &self.earlier,
            .current = &self.current,
            .boundaries = &self.boundaries,
        };
    }
};

pub fn scan(state: *const State, history: *const ScanHistory, first: usize, end: usize) PrefixResult {
    const graph = &state.graph;

    const input: Prefix = .{
        .order = @ptrCast(graph.order),
        .first = first,
        .end = end,
        .entry = graph.entry,
        .sources = &.{ .zx_count = graph.sources.zx_count, .rx_end = graph.sources.rx_end },
        .history = history,
    };

    var empty = std.heap.FixedBufferAllocator.init(&.{});

    return zx.columns.invoke(prefix.executeValue, empty.allocator(), &input) catch unreachable;
}

pub fn reusable(state: *const State, current: *const History.Frame, previous: *const History.Retained, redone: []const bool, digests: History.SourceDigests, index: usize, position: usize) bool {
    const before = extent(&previous.boundaries[position]);
    const after = extent(&previous.boundaries[position + 1]);
    const edges = state.graph.source_dependencies.?;

    const input: Input = .{
        .source = &.{
            .store = state.graph.sources.at(index) == .store,
            .previous_digest = if (previous.digests.at(index)) |value| value else null,
            .current_digest = if (digests.at(index)) |value| value else null,
        },
        .compiled_dependency = state.graph.modules.items(.compiled_dependency)[index],
        .dependencies = &.{ .dependencies = edges.targets, .redone = redone, .first = edges.starts[index], .end = edges.ends[index] },
        .before = &before,
        .after = &after,
    };

    var empty = std.heap.FixedBufferAllocator.init(&.{});
    const eligible = zx.columns.invoke(rule.executeValue, empty.allocator(), &input) catch unreachable;

    return eligible and confirm(state, current, previous, index);
}

pub fn confirm(state: *const State, current: *const History.Frame, previous: *const History.Retained, index: usize) bool {
    const earlier = previous.derived.dependencies.sources.at(index);

    return switch (state.graph.sources.at(index)) {
        .zx => true,
        .rx => |row| earlier == .rx and sameSignature(&previous.derived.resolved[earlier.rx], &current.resolved[row]),
        .store => |row| earlier == .store and @import("../../history/columns.zig").same(previous.derived.stores[earlier.store].node, current.stores[row].node),
    };
}

fn sameSignature(previous: *const Signature, current: *const Signature) bool {
    const compare = @import("generated_rx_mixed_history_signature");
    const Pair = std.meta.Child(compare.Input);
    const Columns = std.meta.Child(@FieldType(Pair, "previous"));
    const left = signature(Columns, previous);
    const right = signature(Columns, current);
    const input: Pair = .{ .previous = &left, .current = &right };
    var empty = std.heap.FixedBufferAllocator.init(&.{});

    return zx.columns.invoke(compare.executeValue, empty.allocator(), &input) catch unreachable;
}

fn signature(comptime Columns: type, source: *const Signature) Columns {
    return .{
        .input_type = @backingInt(source.input_type),
        .output_type = @backingInt(source.output_type),
        .binding_types = std.mem.sliceAsBytes(source.bindings.types),
        .task_types = std.mem.sliceAsBytes(source.tasks),
        .bindings = source.bindings.names,
    };
}

fn extent(checkpoint: *const History.Checkpoint) Extent {
    return .{
        .native_modules = checkpoint.native_modules,
        .initializers = checkpoint.initializers,
        .libraries = checkpoint.libraries,
    };
}
