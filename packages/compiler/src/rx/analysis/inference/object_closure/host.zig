const std = @import("std");
const zx = @import("zx");
const Graph = @import("../types.zig");
const Kind = @import("../nodes.zig").Kind;
const Closure = @import("../object_closure.zig");
const Replay = @import("replay.zig");
pub const Context = std.meta.Child(@FieldType(Replay.View, "readiness"));
const Cache = std.meta.Child(@FieldType(Context, "cache"));

pub const Session = struct {
    closure: *Closure,
    graph: *const Graph,
    cache: Cache = undefined,
    pub fn bind(self: *Session) void {
        const cache = &self.closure.cache;

        self.cache = .{
            .revision = &cache.revision,
            .index = &cache.index,
            .edges = &cache.edges,
            .marks = &cache.marks,
        };
    }
    pub fn context(self: *Session) Context {
        const kinds: []const Kind = self.graph.nodes.items(.kind);

        return .{
            .frame = @ptrCast(self),
            .cache = &self.cache,
            .kinds = zx.columns.slice(@FieldType(Context, "kinds"), kinds),
            .revision = self.graph.object_revision,
            .constructions = self.graph.pending.constructions.len,
            .selections = self.graph.pending.selections.len,
        };
    }

    fn borrow(handle: *const anyopaque) *Session {
        return @ptrCast(@alignCast(@constCast(handle)));
    }
};

pub fn updateObjectReadiness(handle: *const anyopaque, rebuild: bool, position: u64, spread: bool, shared: bool) std.mem.Allocator.Error!bool {
    const session = Session.borrow(handle);
    const closure = session.closure;
    const graph = session.graph;
    const update = @import("generated_rx_update_object_readiness");
    const Update = std.meta.Child(update.Input);
    const Layout = std.meta.Child(@FieldType(Update, "layout"));
    const allocator = closure.arena.allocator();
    const cache = &closure.cache;
    var revision: []u64 = &cache.revision;
    var index: [][]const u32 = &cache.index;
    var edges: [][]const u64 = &cache.edges;
    var marks: [][]const bool = &cache.marks;
    var buffer: [std.heap.page_size_min / 4]u8 = undefined;
    var workspace = std.heap.BufferFirstAllocator.init(&buffer, closure.arena.child_allocator);
    const scratch = workspace.allocator();
    var ready: []bool = &.{};
    var queue: []u64 = &.{};
    var pending: []u64 = &.{};

    errdefer allocator.free(ready);
    defer scratch.free(queue);
    defer scratch.free(pending);

    const kinds: []const Kind = graph.nodes.items(.kind);
    const constructions = graph.pending.constructions.slice();
    const parts = graph.pending.construction_parts.slice();
    const selections = graph.pending.selections.slice();
    const parents = graph.parents();

    const input: Update = .{
        .cache = @ptrCast(&session.cache),
        .slots = &.{
            .revision = @ptrCast(&revision),
            .index = @ptrCast(&index),
            .edges = @ptrCast(&edges),
            .marks = @ptrCast(&marks),
        },
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
            .parents = @ptrCast(&parents),
        },
        .work = &.{
            .ready = @ptrCast(&ready),
            .queue = @ptrCast(&queue),
            .pending = @ptrCast(&pending),
        },
        .arena = @ptrCast(&closure.arena),
        .scratch = @ptrCast(&scratch),
        .revision = graph.object_revision,
        .rebuild = rebuild,
        .position = position,
        .spread = spread,
        .shared = shared,
    };

    return update.executeIn(allocator, &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.Overflow, error.IntegerOverflow => error.OutOfMemory,
        else => unreachable,
    };
}
