const std = @import("std");
const zx = @import("zx");
const Graph = @import("types.zig");
const project = @import("object_closure/project.zig");
const Self = @This();
pub const Query = enum { spread, selection };

arena: std.heap.ArenaAllocator,
snapshot: ?project.Snapshot = null,
pub fn init(allocator: std.mem.Allocator) Self {
    return .{ .arena = .init(allocator) };
}

pub fn deinit(self: *Self) void {
    self.arena.deinit();
}

pub fn prove(self: *Self, graph: *const Graph, value: Graph.Id, query: Query) std.mem.Allocator.Error!bool {
    return self.proveRoot(graph, graph.root(value), query);
}

pub fn proveRoot(self: *Self, graph: *const Graph, root: Graph.Id, query: Query) std.mem.Allocator.Error!bool {
    const kind = graph.nodes.items(.kind)[@backingInt(root)];
    const constructions = graph.pending.constructions.len;
    const selections = graph.pending.selections.len;

    if (comptime !@import("rx_options").generated_graph) {
        if (kind == .Known) return true;
        if (constructions == 0 and selections == 0) return false;

        return @import("object_closure/seed.zig").prove(graph, root, query, 0);
    }

    return @import("object_closure/host.zig").prove(self, graph, root, kind, constructions, selections, query == .spread);
}

pub fn rebuild(self: *Self, graph: *const Graph) std.mem.Allocator.Error!void {
    self.snapshot = null;
    _ = self.arena.reset(.retain_capacity);
    self.snapshot = try project.build(graph, self.arena.allocator());
}

pub fn propagate(self: *Self, constructions: usize, position: u64, spread: bool, shared: bool) std.mem.Allocator.Error!bool {
    const data = &self.snapshot.?;
    const rule = @import("generated_object_closure");
    const allocator = self.arena.allocator();
    const ready = try allocator.alloc(bool, data.known.len);

    errdefer allocator.free(ready);

    var buffer: [std.heap.page_size_min / 4]u8 = undefined;
    var workspace = std.heap.BufferFirstAllocator.init(&buffer, self.arena.child_allocator);
    const scratch = workspace.allocator();
    const queue = try scratch.alloc(u64, data.known.len);

    defer scratch.free(queue);

    const pending = if (data.dependents.len == 0) &.{} else try scratch.alloc(u64, data.sizes.len);

    defer scratch.free(pending);

    const bytes = std.mem.sliceAsBytes(ready);
    const pending_bytes = std.mem.sliceAsBytes(pending);

    const input: std.meta.Child(rule.Input) = .{
        .rules = &.{
            .known = data.known,
            .sizes = data.sizes,
            .results = data.results,
            .offsets = data.offsets,
            .dependents = data.dependents,
            .constructions = constructions,
            .spread = spread,
        },
        .work = &.{
            .ready = ready,
            .ready_output = @ptrCast(&bytes),
            .queue = @ptrCast(&queue),
            .pending = @ptrCast(&pending),
        },
        .counters = &.{ .sizes = std.mem.sliceAsBytes(data.sizes), .pending = @ptrCast(&pending_bytes) },
        .publication = &.{ .position = position, .shared = shared },
    };

    var empty = std.heap.FixedBufferAllocator.init(&.{});
    const result = zx.columns.invoke(rule.executeValue, empty.allocator(), &input) catch unreachable;

    if (result.spread) data.query.spread = ready;
    if (result.selection) data.query.selection = ready;

    return result.ready;
}
