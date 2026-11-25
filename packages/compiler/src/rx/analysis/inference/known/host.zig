const std = @import("std");
const zx = @import("zx");
const Graph = @import("../types.zig");
const Nodes = @import("../nodes.zig");
const Known = @import("../known.zig");
const Buckets = Known.Buckets;
const rule = @import("generated_rx_register_known_types");
const Input = std.meta.Child(rule.Input);
const Registry = std.meta.Child(@FieldType(Input, "view"));
const Table = std.meta.Child(@FieldType(Registry, "table"));
const Storage = std.meta.Child(@FieldType(Registry, "storage"));
const NodeView = std.meta.Child(@FieldType(Registry, "nodes"));
const Columns = std.meta.Child(@FieldType(NodeView, "columns"));
const Publication = std.meta.Child(@FieldType(Input, "publication"));

const Writable = struct {
    metadata: []u8,
    keys: []u32,
    values: []u32,
    fn from(rows: Buckets.Slice) Writable {
        return .{ .metadata = rows.items(.metadata), .keys = rows.items(.keys), .values = rows.items(.values) };
    }
    fn borrow(self: *Writable, comptime Target: type) Target {
        return .{ .metadata = @ptrCast(&self.metadata), .keys = @ptrCast(&self.keys), .values = @ptrCast(&self.values) };
    }
};

const Frame = struct {
    graph: *Graph,
    span: zx.Span,
    rows: Nodes.Storage.Slice = undefined,
    columns: Nodes.Writable = undefined,
    writable: Writable = undefined,
    parents: []u32 = undefined,
    table: Table = undefined,
    storage: Storage = undefined,
    shape_columns: Columns = undefined,
    nodes: NodeView = undefined,
    registry: Registry = undefined,
    count: []u64 = undefined,
    node_publication: Nodes.Publication = undefined,
    visibility: std.meta.Child(@FieldType(Publication, "storage")) = undefined,
    spans: std.meta.Child(@FieldType(Publication, "span")) = undefined,
    fn bind(self: *Frame) void {
        const graph = self.graph;
        const known = &graph.pending.known_types;
        self.rows = graph.nodes.slice();
        self.rows.len = graph.nodes.capacity;
        self.columns = Nodes.writable(self.rows);
        self.writable = Writable.from(known.state.buckets);
        self.parents = self.rows.items(.parent);
        self.table = known.borrow(Table);
        self.storage = self.writable.borrow(Storage);
        self.shape_columns = self.columns.borrow(Columns);
        self.nodes = .{ .parents = @ptrCast(&self.parents), .columns = &self.shape_columns, .capacity = self.rows.len, .known_kind = @backingInt(Nodes.Kind.Known) };
        self.count = (&known.state.count)[0..1];
        self.node_publication = Nodes.Publication.init(graph, self.rows);
        self.visibility = self.node_publication.storage(@TypeOf(self.visibility));
        self.spans = self.node_publication.span(@TypeOf(self.spans), self.span);
    }
    fn borrow(handle: *const anyopaque) *Frame {
        return @ptrCast(@alignCast(@constCast(handle)));
    }
};

pub fn register(graph: *Graph, members: []const u32, budget: ?u64, span: zx.Span) zx.Error!Known.Registration {
    var frame: Frame = .{ .graph = graph, .span = span };

    frame.bind();

    frame.registry = .{ .table = &frame.table, .storage = &frame.storage, .nodes = &frame.nodes };

    const input: Input = .{
        .frame = @ptrCast(&frame),
        .view = &frame.registry,
        .types = &.{ .kinds = graph.types.items.kinds.items, .children = graph.types.items.first.items },
        .members = members,
        .type_id = members[0],
        .remaining = budget,
        .end = graph.nodes.len,
        .publication = &.{ .storage = &frame.visibility, .span = &frame.spans, .count = @ptrCast(&frame.count) },
    };

    var empty = std.heap.FixedBufferAllocator.init(&.{});
    const workflow = @import("../../project/workflow/errors.zig");
    const result = zx.columns.invoke(rule.executeValue, empty.allocator(), &input) catch |err| return workflow.errorSet(err);

    return .{ .node = @fromBackingInt(result.value), .remaining = result.remaining orelse 0 };
}

pub fn reserveKnownNodes(handle: *const anyopaque) std.mem.Allocator.Error!void {
    _ = try Nodes.reserve(Frame.borrow(handle).graph, 1);
}

pub fn reserveKnownIndex(handle: *const anyopaque, capacity: u64) std.mem.Allocator.Error!void {
    const graph = Frame.borrow(handle).graph;
    const table = &graph.pending.known_types;
    const allocator = graph.pending.allocator;
    const rehash = @import("generated_rx_known_rehash");
    const RehashInput = std.meta.Child(rehash.Input);
    const size = std.math.cast(u32, capacity) orelse return error.OutOfMemory;

    if (size > std.math.maxInt(usize) / Buckets.capacityInBytes(1)) return error.OutOfMemory;

    var fresh: Buckets = .empty;

    try fresh.setCapacity(allocator, size);

    fresh.len = size;
    const rows = fresh.toOwnedSlice();
    var storage = Writable.from(rows);

    const input: RehashInput = .{
        .previous = &table.borrow(std.meta.Child(@FieldType(RehashInput, "previous"))),
        .metadata = storage.metadata,
        .keys = storage.keys,
        .storage = &storage.borrow(std.meta.Child(@FieldType(RehashInput, "storage"))),
    };

    var empty = std.heap.FixedBufferAllocator.init(&.{});

    zx.columns.invoke(rehash.executeValue, empty.allocator(), &input) catch unreachable;
    table.state.buckets.deinit(allocator);

    table.state.buckets = rows;
}

pub fn refreshKnownRegistry(handle: *const anyopaque) void {
    Frame.borrow(handle).bind();
}

pub fn rejectKnownType(handle: *const anyopaque) zx.Error!void {
    const frame = Frame.borrow(handle);

    return Known.invalid(frame.graph, frame.span);
}
