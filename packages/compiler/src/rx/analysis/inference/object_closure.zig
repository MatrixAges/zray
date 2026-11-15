const std = @import("std");
const zx = @import("zx");
const Graph = @import("types.zig");
const Fields = @import("fields/view.zig");
const Columns = @import("fields/columns.zig");
const project = @import("object_closure/project.zig");
const Self = @This();
pub const Query = enum { spread, selection };

const Selection = struct { row: usize, root: Graph.Id, mode: Fields.Mode, ready: bool };

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

    const spread = query == .spread;
    var empty = std.heap.FixedBufferAllocator.init(&.{});

    while (true) {
        const input: project.QueryInput = .{
            .root = @backingInt(root),
            .kind = kind,
            .revision = graph.object_revision,
            .constructions = constructions,
            .selections = selections,
            .snapshot = self.cached(),
            .spread = spread,
        };

        const plan = zx.columns.invoke(project.query.executeValue, empty.allocator(), &input) catch unreachable;

        switch (plan.action) {
            .Accept => return true,
            .Reject => return false,
            .Rebuild => try self.rebuild(graph),
            .Propagate => return self.propagate(constructions, plan.position, spread, plan.shared),
        }
    }
}

pub fn nextSelection(self: *Self, graph: *const Graph, sources: []const Graph.Id, first: usize, final: bool) std.mem.Allocator.Error!?Selection {
    const rule = @import("generated_rx_selection_ready");
    const Input = std.meta.Child(rule.Input);
    const columns = Columns.borrow(std.meta.Child(@FieldType(Input, "columns")), graph);
    const parents = graph.parents();
    const constructions = graph.pending.constructions.len;
    var start = first;
    var empty = std.heap.FixedBufferAllocator.init(&.{});

    while (start < sources.len) {
        const snapshot = self.cached();

        const input: Input = .{
            .parents = @ptrCast(&parents),
            .columns = &columns,
            .sources = @ptrCast(sources),
            .revision = graph.object_revision,
            .constructions = constructions,
            .snapshot = if (snapshot) |value| zx.columns.pointer(@typeInfo(@FieldType(Input, "snapshot")).optional.child, value) else null,
            .start = start,
            .final = final,
        };

        const result = zx.columns.invoke(rule.executeValue, empty.allocator(), &input) catch unreachable;
        const row: usize = @intCast(result.row);

        if (row == sources.len) return null;

        const plan = result.plan;
        const root: Graph.Id = @fromBackingInt(result.root);
        const mode: Fields.Mode = @fromBackingInt(@backingInt(result.mode));

        switch (plan.action) {
            .Accept => return .{ .row = row, .root = root, .mode = mode, .ready = true },
            .Reject => return .{ .row = row, .root = root, .mode = mode, .ready = false },
            .Rebuild => {
                try self.rebuild(graph);

                start = row;
            },
            .Propagate => {
                const ready = try self.propagate(constructions, plan.position, false, plan.shared);

                if (ready or final) return .{ .row = row, .root = root, .mode = mode, .ready = ready };

                start = row + 1;
            },
        }
    }

    return null;
}

fn cached(self: *const Self) ?*const project.QuerySnapshot {
    return if (self.snapshot) |*data| &data.query else null;
}

fn rebuild(self: *Self, graph: *const Graph) std.mem.Allocator.Error!void {
    self.snapshot = null;
    _ = self.arena.reset(.retain_capacity);
    self.snapshot = try project.build(graph, self.arena.allocator());
}

fn propagate(self: *Self, constructions: usize, position: u64, spread: bool, shared: bool) std.mem.Allocator.Error!bool {
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
