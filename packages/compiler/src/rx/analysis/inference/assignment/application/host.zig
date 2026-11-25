const std = @import("std");
const zx = @import("zx");
const Graph = @import("../../types.zig");
const Known = @import("../../known.zig");
const Topology = @import("../../optional/topology.zig").borrowType;
const Solve = @import("../../../project/workflow/solve/abi.zig").Solve;
const Request = child(Solve, "assignments");
const View = child(Request, "view");
const Validation = child(Solve, "validation");
const Classes = child(Request, "classes");
const Rows = child(Request, "rows");
const Sequences = child(Request, "sequences");

pub const Frame = struct {
    graph: *Graph,
    workspace: *std.heap.ArenaAllocator,
    view: Request,
    validation: Validation,
    validation_columns: child(Validation, "columns"),
    topology: Topology(View),
    merge_view: View,
    nodes: child(Request, "nodes"),
    revision: []u64,
    node_spans: []const zx.Span,
    classes: Classes,
    storage: child(Classes, "storage"),
    groups: []u32,
    representatives: []?u32,
    ranks: []u8,
    edges: child(Rows, "edges"),
    write: child(Rows, "write"),
    rows: Rows,
    left: []u32,
    right: []u32,
    spans: []const zx.Span,
    payloads: child(Request, "payloads"),
    active: []u32,
    initial: []u32,
    registered: []u32,
    remaining: u64,
    sequences: Sequences,
    sequence_rows: child(Sequences, "sequence"),
    sequence_spans: []const zx.Span,
    indexes: child(Request, "indexes"),
    bounds: child(Request, "bounds"),
    depths: []u64,
    deferred: []u64,
    pub fn bind(self: *Frame, graph: *Graph, workspace: *std.heap.ArenaAllocator) void {
        self.graph = graph;
        self.workspace = workspace;
        self.revision = (&graph.revision)[0..1];

        self.refresh();

        const edges = graph.pending.assignments.slice();

        self.left = @ptrCast(edges.items(.value));
        self.right = @ptrCast(edges.items(.expected));
        self.spans = edges.items(.span);
        self.edges = .{ .left = self.left, .right = self.right };
        self.write = .{ .left = @ptrCast(&self.left), .right = @ptrCast(&self.right), .count = self.left.len };
        self.rows = .{ .edges = &self.edges, .write = &self.write, .spans = @ptrCast(&self.spans) };

        const sequences = graph.pending.sequences.slice();

        self.sequence_rows = .{ .values = @ptrCast(sequences.items(.value)), .elements = @ptrCast(sequences.items(.elements)) };
        self.sequence_spans = sequences.items(.span);
        self.sequences.sequence = &self.sequence_rows;
        self.sequences.spans = @ptrCast(&self.sequence_spans);

        const indexes = graph.pending.indexes.slice();

        self.indexes = .{ .values = @ptrCast(indexes.items(.value)), .resolved = indexes.items(.resolved) };
        self.payloads = .{ .active = @ptrCast(&self.active), .initial = @ptrCast(&self.initial), .registered = @ptrCast(&self.registered) };
        self.bounds = .{ .depths = @ptrCast(&self.depths), .deferred = @ptrCast(&self.deferred) };

        self.view = .{
            .frame = @ptrCast(self),
            .owner = @ptrCast(graph),
            .arena = @ptrCast(workspace),
            .view = &self.merge_view,
            .nodes = &self.nodes,
            .classes = &self.classes,
            .rows = &self.rows,
            .payloads = &self.payloads,
            .sequences = &self.sequences,
            .indexes = &self.indexes,
            .bounds = &self.bounds,
            .node_spans = @ptrCast(&self.node_spans),
            .revision = @ptrCast(&self.revision),
        };
    }

    pub fn bindValidation(self: *Frame, graph: *Graph, handle: *anyopaque, resolver: @FieldType(Validation, "resolver")) void {
        const edges = graph.pending.assignments.slice();

        self.spans = edges.items(.span);

        self.topology.bind(graph);

        self.validation_columns = .{
            .graph = &self.topology.graph,
            .left = @ptrCast(edges.items(.value)),
            .right = @ptrCast(edges.items(.expected)),
            .parents = @ptrCast(&self.topology.parents),
        };

        self.validation = .{
            .frame = @ptrCast(handle),
            .resolver = resolver,
            .owner = @ptrCast(graph),
            .spans = @ptrCast(&self.spans),
            .columns = &self.validation_columns,
        };
    }
    fn refresh(self: *Frame) void {
        const rows = self.graph.nodes.slice();

        self.topology.bind(self.graph);

        self.node_spans = rows.items(.span);
        self.nodes = .{ .kinds = self.topology.graph.kinds, .allowed = rows.items(.allowed) };
        self.sequences.members = rows.items(.members);

        self.merge_view = .{
            .graph = &self.topology.graph,
            .parents = @ptrCast(&self.topology.parents),
            .known = &self.topology.known,
            .allowed = self.nodes.allowed,
        };
    }

    fn borrow(handle: *anyopaque) *Frame {
        return @ptrCast(@alignCast(handle));
    }
};

fn child(comptime T: type, comptime field: []const u8) type {
    return std.meta.Child(@FieldType(T, field));
}

pub fn assignmentRevision(handle: *anyopaque) u64 {
    return Frame.borrow(handle).graph.revision;
}

pub fn beginInitialAssignmentPayloads(handle: *anyopaque) std.mem.Allocator.Error!u64 {
    const frame = Frame.borrow(handle);
    frame.initial = try frame.workspace.allocator().alloc(u32, frame.graph.nodes.len);
    frame.active = frame.initial;

    return frame.initial.len;
}

pub fn beginRegisteredAssignmentPayloads(handle: *anyopaque, first: u64) std.mem.Allocator.Error!u64 {
    const frame = Frame.borrow(handle);
    const count = frame.graph.nodes.len;
    frame.registered = try frame.workspace.allocator().alloc(u32, count - @as(usize, @intCast(first)));
    frame.active = frame.registered;

    return count;
}

pub fn reserveAssignmentClasses(handle: *anyopaque) std.mem.Allocator.Error!void {
    const frame = Frame.borrow(handle);
    const allocator = frame.workspace.allocator();
    const count = frame.graph.nodes.len;

    std.debug.assert(count == frame.initial.len + frame.registered.len);

    frame.groups = try allocator.alloc(u32, count);
    frame.representatives = try allocator.alloc(?u32, count);
    frame.ranks = try allocator.alloc(u8, count);
    frame.storage = .{ .parents = @ptrCast(&frame.groups), .ranks = @ptrCast(&frame.ranks), .representatives = @ptrCast(&frame.representatives) };
    frame.classes = .{ .groups = frame.groups, .representatives = frame.representatives, .ranks = frame.ranks, .storage = &frame.storage };
}

pub fn releaseAssignmentRanks(handle: *anyopaque) void {
    const frame = Frame.borrow(handle);

    frame.workspace.allocator().free(frame.ranks);
}

pub fn reserveAssignmentDepths(handle: *anyopaque) std.mem.Allocator.Error![]const u64 {
    const frame = Frame.borrow(handle);
    frame.depths = try frame.workspace.allocator().alloc(u64, frame.graph.nodes.len);

    return frame.depths;
}

pub fn reserveDeferredAssignments(handle: *anyopaque, words: u64) std.mem.Allocator.Error![]const u64 {
    const frame = Frame.borrow(handle);

    frame.deferred = try frame.workspace.allocator().alloc(u64, @intCast(words));

    @memset(frame.deferred, 0);

    return frame.deferred;
}

pub fn registerAssignmentPayload(handle: *anyopaque, node: u32, value: u32, remaining: u64) zx.Error!u32 {
    const frame = Frame.borrow(handle);
    const registered = try Known.registerPayload(frame.graph, value, remaining, frame.node_spans[node]);

    frame.remaining = registered.remaining;

    frame.refresh();

    return @backingInt(registered.node);
}

pub fn remainingAssignmentDepth(handle: *anyopaque) u64 {
    return Frame.borrow(handle).remaining;
}

pub fn rejectAssignmentDepth(handle: *anyopaque, node: u32) zx.Error!void {
    const frame = Frame.borrow(handle);

    return frame.graph.reporter.fail(.unsupported, frame.node_spans[node], "type inference nesting exceeds 256 levels");
}

pub fn mergeAssignmentClass(handle: *anyopaque, row: u64, other: u32) zx.Error!void {
    const frame = Frame.borrow(handle);
    const index: u32 = @intCast(row);

    try frame.graph.unify(@fromBackingInt(index), @fromBackingInt(other), frame.graph.nodes.items(.span)[index]);

    frame.refresh();
}

pub fn reserveAssignmentOptional(handle: *anyopaque, node: u32, payload: u32, layers: u64) zx.Error!u32 {
    const graph = Frame.borrow(handle).graph;
    const span = graph.nodes.items(.span)[node];
    const count = std.math.cast(usize, layers) orelse return error.OutOfMemory;

    return @backingInt(try graph.addContainers(@fromBackingInt(payload), .optional, count, span));
}
