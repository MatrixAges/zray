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
        .zx_count = graph.sources.zx_count,
        .history = history,
    };

    var empty = std.heap.FixedBufferAllocator.init(&.{});

    return zx.columns.invoke(prefix.executeValue, empty.allocator(), &input) catch unreachable;
}

pub fn reusable(state: *const State, current: History.Frame, previous: *const History.Retained, redone: ?[]const bool, digests: History.SourceDigests, index: usize, position: usize) bool {
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
            if (previous.digests.at(index)) |digest| source.previous_digest = digest;
            if (digests.at(index)) |digest| source.current_digest = digest;

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
