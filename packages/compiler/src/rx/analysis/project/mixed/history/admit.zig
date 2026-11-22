const std = @import("std");
const zx = @import("zx");
const History = @import("../../history.zig");
const Signature = @import("../../signatures.zig").Signature;
const State = @import("../state.zig");
const Module = @import("rx").ModuleSource;
const rule = @import("generated_rx_mixed_history_reuse");
const Input = std.meta.Child(rule.Input);
const Extent = std.meta.Child(@FieldType(Input, "before"));
const prefix = @import("generated_rx_mixed_history_advance");
const Prefix = std.meta.Child(prefix.Input);
pub const ScanHistory = std.meta.Child(@FieldType(Prefix, "history"));

pub const Borrowed = struct {
    dependencies: std.meta.Child(@FieldType(ScanHistory, "dependencies")),
    earlier: std.meta.Child(@FieldType(ScanHistory, "earlier")),
    current: std.meta.Child(@FieldType(ScanHistory, "current")),
    boundaries: std.meta.Child(@FieldType(ScanHistory, "boundaries")),
    previous_sources: std.meta.Child(@FieldType(ScanHistory, "previous_sources")),
    earlier_view: SignatureView,
    current_view: SignatureView,
    signatures: SignaturePair,
    earlier_stores: []const Module,
    current_stores: []const Module,
    stores: Stores,
    history: ScanHistory,
    pub fn init(self: *Borrowed, state: *const State, current: *const History.Frame, previous: *const History.Retained, digests: History.SourceDigests, redone: []const bool) void {
        const graph = &state.graph;
        const edges = graph.source_dependencies.?;
        const word = @sizeOf(u64);

        comptime {
            const Checkpoint = History.Checkpoint;
            const offset = @offsetOf(Checkpoint, "native_modules");

            if (@offsetOf(Checkpoint, "initializers") != offset + word or @offsetOf(Checkpoint, "libraries") != offset + 2 * word) @compileError("mixed history link counters must be adjacent native words");
        }

        self.* = .{
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
            .previous_sources = .{ .zx_count = previous.derived.dependencies.sources.zx_count, .rx_end = previous.derived.dependencies.sources.rx_end },
            .earlier_view = undefined,
            .current_view = undefined,
            .signatures = undefined,
            .earlier_stores = undefined,
            .current_stores = undefined,
            .stores = undefined,
            .history = undefined,
        };

        const earlier = &previous.derived;
        const shared = self.previous_sources.zx_count == graph.sources.zx_count and earlier.resolved.inputs.ptr == current.resolved.inputs.ptr and earlier.resolved.inputs.len == current.resolved.inputs.len;

        if (!shared) {
            self.earlier_view = signatureColumns(&earlier.resolved);
            self.current_view = signatureColumns(&current.resolved);
            self.signatures = .{ .earlier = &self.earlier_view, .current = &self.current_view };
        }

        const shared_stores = self.previous_sources.rx_end == graph.sources.rx_end and earlier.stores.ptr == current.stores.ptr and earlier.stores.len == current.stores.len;

        if (!shared_stores) {
            self.earlier_stores = earlier.stores;
            self.current_stores = current.stores;
            self.stores = .{ .earlier = @ptrCast(&self.earlier_stores), .current = @ptrCast(&self.current_stores) };
        }

        self.history = .{
            .previous_sources = &self.previous_sources,
            .signatures = if (shared) null else &self.signatures,
            .stores = if (shared_stores) null else &self.stores,
            .dependencies = &self.dependencies,
            .earlier = &self.earlier,
            .current = &self.current,
            .boundaries = &self.boundaries,
        };
    }
};

const Stores = optionalField(ScanHistory, "stores");

fn optionalField(comptime Record: type, comptime name: []const u8) type {
    return std.meta.Child(@typeInfo(@FieldType(Record, name)).optional.child);
}

const SignaturePair = std.meta.Child(@typeInfo(@FieldType(ScanHistory, "signatures")).optional.child);
const SignatureView = std.meta.Child(@FieldType(SignaturePair, "earlier"));

fn signatureColumns(table: *const @import("../../signatures.zig").Table) SignatureView {
    return .{
        .inputs = table.inputs,
        .outputs = table.outputs,
        .binding_ends = table.binding_ends,
        .task_ends = table.task_ends,
        .names = table.names,
        .bindings = std.mem.sliceAsBytes(table.binding_types),
        .tasks = std.mem.sliceAsBytes(table.task_types),
    };
}

pub fn advance(state: *const State, history: *const ScanHistory, first: usize, end: usize) usize {
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

    return @intCast(zx.columns.invoke(prefix.executeValue, empty.allocator(), &input) catch unreachable);
}

const Confirmation = std.meta.Child(@FieldType(Input, "confirmation"));
const Signatures = optionalField(Confirmation, "signature");
const Ports = std.meta.Child(@FieldType(Signatures, "previous"));
const Nodes = optionalField(Confirmation, "store");

pub fn reusable(state: *const State, current: *const History.Frame, previous: *const History.Retained, redone: []const bool, digests: History.SourceDigests, index: usize, position: usize) bool {
    const before = extent(&previous.boundaries[position]);
    const after = extent(&previous.boundaries[position + 1]);
    const edges = state.graph.source_dependencies.?;
    const earlier_source = previous.derived.dependencies.sources.at(index);
    const current_source = state.graph.sources.at(index);
    var left: Ports = undefined;
    var right: Ports = undefined;
    var pair: Signatures = undefined;
    var nodes: Nodes = undefined;
    var confirmation: Confirmation = .{ .matches = true, .signature = null, .store = null };

    switch (current_source) {
        .zx => {},
        .rx => |row| {
            confirmation.matches = earlier_source == .rx;

            if (confirmation.matches) {
                left = signature(Ports, &previous.derived.resolved.at(earlier_source.rx));
                right = signature(Ports, &current.resolved.at(row));
                pair = .{ .previous = &left, .current = &right };
                confirmation.signature = &pair;
            }
        },
        .store => |row| {
            confirmation.matches = earlier_source == .store;

            if (confirmation.matches) {
                nodes = .{
                    .@"0" = @ptrCast(&previous.derived.stores[earlier_source.store].node),
                    .@"1" = @ptrCast(&current.stores[row].node),
                };

                confirmation.store = &nodes;
            }
        },
    }

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
        .confirmation = &confirmation,
    };

    var empty = std.heap.FixedBufferAllocator.init(&.{});

    return zx.columns.invoke(rule.executeValue, empty.allocator(), &input) catch unreachable;
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
