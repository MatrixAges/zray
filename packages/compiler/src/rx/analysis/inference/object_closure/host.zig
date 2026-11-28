const std = @import("std");
const zx = @import("zx");
const Graph = @import("../types.zig");
const Kind = @import("../nodes.zig").Kind;
const Closure = @import("../object_closure.zig");
const Replay = @import("replay.zig");
pub const Context = std.meta.Child(@FieldType(Replay.View, "readiness"));
const Cache = std.meta.Child(@FieldType(Context, "cache"));

const Slot = struct {
    const keys: usize = 0;
    const buckets: usize = 1;
    const sizes: usize = 0;
    const results: usize = 1;
    const offsets: usize = 2;
    const dependents: usize = 3;
    const known: usize = 0;
    const spread: usize = 1;
    const selection: usize = 2;
};

pub const Session = struct {
    closure: *Closure,
    graph: *const Graph,
    cache: Cache = undefined,
    pub fn bind(self: *Session) void {
        const cache = &self.closure.cache;

        self.cache = .{
            .revision = cache.revision,
            .index = &cache.index,
            .edges = &cache.edges,
            .marks = &cache.marks,
        };
    }

    pub fn context(self: *Session) Context {
        const kinds: []const Kind = self.graph.nodes.items(.kind);

        return .{
            .cache = &self.cache,
            .kinds = zx.columns.slice(@FieldType(Context, "kinds"), kinds),
            .revision = self.graph.object_revision,
            .constructions = self.graph.pending.constructions.len,
            .selections = self.graph.pending.selections.len,
        };
    }
};

pub fn updateReadiness(session: *Session, rebuild: bool, position: u64, spread: bool, shared: bool) std.mem.Allocator.Error!bool {
    const closure = session.closure;
    const graph = session.graph;
    const update = @import("generated_rx_update_object_readiness");
    const Update = std.meta.Child(update.Input);
    const Layout = std.meta.Child(@FieldType(Update, "layout"));
    const cache = &closure.cache;

    if (rebuild) {
        cache.index[Slot.keys] = &.{};
        _ = closure.arena.reset(.retain_capacity);
    }

    const allocator = closure.arena.allocator();
    const kinds: []const Kind = graph.nodes.items(.kind);
    const constructions = graph.pending.constructions.slice();
    const parts = graph.pending.construction_parts.slice();
    const selections = graph.pending.selections.slice();

    const input: Update = .{
        .cache = @ptrCast(&session.cache),
        .layout = &.{
            .kinds = zx.columns.slice(@FieldType(Layout, "kinds"), kinds),
            .columns = &.{
                .construction_results = @ptrCast(constructions.items(.result)),
                .part_first = constructions.items(.first),
                .part_count = constructions.items(.count),
                .part_names = parts.items(.name),
                .part_values = @ptrCast(parts.items(.value)),
                .selection_results = @ptrCast(selections.items(.result)),
                .selection_sources = @ptrCast(selections.items(.source)),
            },
            .parents = graph.parents(),
        },
        .revision = graph.object_revision,
        .rebuild = rebuild,
        .spread = spread,
    };

    const outcome = update.executeIn(allocator, &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.Overflow, error.IntegerOverflow => return error.OutOfMemory,
        else => unreachable,
    };

    if (outcome.revision) |next| {
        cache.revision = next;
        session.cache.revision = next;
    }

    if (outcome.snapshot) |snapshot| {
        cache.edges[Slot.sizes] = snapshot.sizes;
        cache.edges[Slot.results] = snapshot.results;
        cache.edges[Slot.offsets] = snapshot.offsets;
        cache.edges[Slot.dependents] = snapshot.dependents;
        cache.marks[Slot.known] = snapshot.known;
        cache.marks[Slot.spread] = &.{};
        cache.marks[Slot.selection] = &.{};
        cache.index[Slot.buckets] = snapshot.buckets;
        cache.index[Slot.keys] = snapshot.keys;
    }

    if (outcome.marks) |marks| {
        if (spread or shared) cache.marks[Slot.spread] = marks;
        if (!spread or shared) cache.marks[Slot.selection] = marks;

        return marks[@intCast(position)];
    }

    return false;
}
