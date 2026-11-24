const std = @import("std");
const zx = @import("zx");
const History = @import("../../history.zig");
const State = @import("../state.zig");
const Module = @import("rx").ModuleSource;
const columns = @import("../../history/columns.zig");
const Transfer = zx.memory.column_transfer;
const Checkpoint = History.Checkpoint;
const rule = @import("generated_rx_mixed_history_replay");
const Window = std.meta.Child(@FieldType(std.meta.Child(rule.Input), "window"));
pub const ScanHistory = std.meta.Child(@FieldType(Window, "history"));
const type_count = @typeInfo(@FieldType(Checkpoint, "types")).array.len;
const origin_count = @typeInfo(@FieldType(Checkpoint, "origins")).array.len;
const function_count = @typeInfo(zx.ir.FunctionStorage).@"struct".field_names.len;

pub const Borrowed = struct {
    dependencies: std.meta.Child(@FieldType(ScanHistory, "dependencies")),
    earlier: std.meta.Child(@FieldType(ScanHistory, "earlier")),
    current: std.meta.Child(@FieldType(ScanHistory, "current")),
    boundaries: std.meta.Child(@FieldType(ScanHistory, "boundaries")),
    checkpoint_words: zx.memory.ReadColumn,
    previous_sources: std.meta.Child(@FieldType(ScanHistory, "previous_sources")),
    earlier_view: SignatureView,
    current_view: SignatureView,
    signatures: SignaturePair,
    stores: Stores,
    history: ScanHistory,
    transfers: [type_count + origin_count + function_count]Transfer.Column,
    group: []const Transfer.Column,
    pub fn init(self: *Borrowed, state: *State, current: *const History.Frame, previous: *const History.Retained, digests: History.SourceDigests, redone: []const bool) void {
        const graph = &state.graph;
        const edges = graph.source_dependencies.?;
        const word = @sizeOf(usize);

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
            .checkpoint_words = columns.words(std.mem.sliceAsBytes(previous.boundaries)),
            .boundaries = undefined,
            .previous_sources = .{ .zx_count = previous.derived.dependencies.sources.zx_count, .rx_end = previous.derived.dependencies.sources.rx_end },
            .earlier_view = undefined,
            .current_view = undefined,
            .signatures = undefined,
            .stores = undefined,
            .history = undefined,
            .transfers = undefined,
            .group = undefined,
        };

        self.boundaries = .{
            .words = @ptrCast(&self.checkpoint_words),
            .stride = @sizeOf(Checkpoint) / word,
            .functions_offset = Checkpoint.function_slot,
        };

        columns.bindTransfers(self.transfers[0..type_count], &state.types.items, previous.types);
        columns.bindTransfers(self.transfers[type_count..][0..origin_count], &state.types.origins.items, previous.origins);
        columns.bindTransfers(self.transfers[type_count + origin_count ..], &state.functions, previous.functions);

        self.group = &self.transfers;

        const earlier = &previous.derived;
        const shared = self.previous_sources.zx_count == graph.sources.zx_count and earlier.resolved.inputs.ptr == current.resolved.inputs.ptr and earlier.resolved.inputs.len == current.resolved.inputs.len;

        if (!shared) {
            self.earlier_view = signatureColumns(&earlier.resolved);
            self.current_view = signatureColumns(&current.resolved);
            self.signatures = .{ .earlier = &self.earlier_view, .current = &self.current_view };
        }

        const shared_stores = self.previous_sources.rx_end == graph.sources.rx_end and earlier.stores.ptr == current.stores.ptr and earlier.stores.len == current.stores.len;

        if (!shared_stores) {
            const Layout = std.meta.Child(@FieldType(Stores, "layout"));

            self.stores = .{
                .earlier = std.mem.sliceAsBytes(earlier.stores),
                .current = std.mem.sliceAsBytes(current.stores),
                .width = @sizeOf(Module),
                .node_offset = @offsetOf(Module, "node"),
                .layout = &comptime @import("rx").astLayout(Layout),
            };
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
