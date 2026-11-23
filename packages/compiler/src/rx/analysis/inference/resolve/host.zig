const std = @import("std");
const zx = @import("zx");
const Graph = @import("../types.zig");
const Nodes = @import("../nodes.zig");
const Workspace = @import("../resolve.zig").Workspace;
const frontend = @import("frontend");
const Writer = frontend.type_publication_view;
const Scratch = @import("../scoped_scratch.zig").Buffer(512);
const Solve = @import("../../project/workflow/solve/abi.zig").Solve;
const Validation = std.meta.Child(@FieldType(Solve, "validation"));
const Session = std.meta.Child(@FieldType(Validation, "resolver"));
const View = std.meta.Child(@FieldType(Session, "graph"));
const Tables = std.meta.Child(@FieldType(Session, "tables"));
const Table = std.meta.Child(@FieldType(Tables, "base"));
const TypeWrite = std.meta.Child(@FieldType(Session, "write"));
const no_origins: std.meta.Child(@FieldType(TypeWrite, "origins")) = .{ .ids = &.{}, .kinds = &.{}, .owners = &.{}, .members = &.{} };
const empty_table = zx.ir.TypeTable.borrow(Table, .{});

pub const Frame = struct {
    graph: *Graph = undefined,
    rows: Nodes.Storage.Slice = undefined,
    workspace: *Workspace = undefined,
    scope: *zx.memory.ArenaScope = undefined,
    scratch: Scratch = .{},
    frames: []u64 = undefined,
    values: []u32 = undefined,
    parents: []u32 = undefined,
    kind_bytes: []u8 = undefined,
    arguments: []u32 = undefined,
    revision: []u64 = undefined,
    graph_view: View = undefined,
    publication: std.meta.Child(@FieldType(Session, "publication")) = undefined,
    view: Session = undefined,
    tables: Tables = undefined,
    base: Table = undefined,
    payload: std.meta.Child(@FieldType(Session, "payload")) = undefined,
    writer: Writer = undefined,
    storage: Writer.Options = undefined,
    write: TypeWrite = undefined,
    delta: Table = undefined,
    row_kind: u8 = undefined,
    row_first: u32 = undefined,
    row_second: u32 = undefined,
    row_label: []const u8 = undefined,
    pub fn bind(self: *Frame, graph: *Graph, workspace: *Workspace, scope: *zx.memory.ArenaScope) void {
        const rows = graph.nodes.slice();
        const kinds: []const Nodes.Kind = rows.items(.kind);

        self.graph = graph;
        self.rows = rows;
        self.workspace = workspace;
        self.scope = scope;
        self.parents = graph.parents();
        self.kind_bytes = std.mem.sliceAsBytes(rows.items(.kind));
        self.arguments = rows.items(.argument);
        self.revision = (&graph.object_revision)[0..1];
        self.frames = if (workspace.extra_frames.capacity == 0) &workspace.local_frames else workspace.extra_frames.allocatedSlice();
        self.values = if (workspace.extra_values.capacity == 0) &workspace.local_values else workspace.extra_values.allocatedSlice();

        comptime std.debug.assert(@sizeOf(Nodes.Kind) == @sizeOf(u8));

        self.graph_view = .{
            .kinds = zx.columns.slice(@FieldType(View, "kinds"), kinds),
            .arguments = self.arguments,
            .members = rows.items(.members),
            .allowed = rows.items(.allowed),
            .fallback = rows.items(.fallback),
        };

        self.publication = .{
            .kinds = @ptrCast(&self.kind_bytes),
            .arguments = @ptrCast(&self.arguments),
            .revision = @ptrCast(&self.revision),
            .known_kind = @backingInt(Nodes.Kind.Known),
        };

        self.tables = .{ .base = &self.base, .delta = &empty_table };

        self.view = .{
            .frame = @ptrCast(self),
            .graph = &self.graph_view,
            .publication = &self.publication,
            .parents = @ptrCast(&self.parents),
            .frames = @ptrCast(&self.frames),
            .values = @ptrCast(&self.values),
            .frame_capacity = self.frames.len,
            .value_capacity = self.values.len,
            .tables = &self.tables,
            .payload = &self.payload,
            .write = &self.write,
        };
    }

    pub fn close(self: *Frame) void {
        if (self.scratch.previous != null) self.scratch.close(self.scope);
    }

    fn borrow(handle: *const anyopaque) *Frame {
        return @ptrCast(@alignCast(@constCast(handle)));
    }
};

pub fn reserveResolveFrames(handle: *const anyopaque, used: u64, added: u64) std.mem.Allocator.Error!u64 {
    const frame = Frame.borrow(handle);

    frame.frames = try grow(u64, frame.graph.scratch, &frame.workspace.extra_frames, frame.frames, @intCast(used), @intCast(added));
    frame.view.frame_capacity = frame.frames.len;

    return frame.view.frame_capacity;
}

pub fn reserveResolveValues(handle: *const anyopaque, used: u64, added: u64) std.mem.Allocator.Error!u64 {
    const frame = Frame.borrow(handle);

    frame.values = try grow(u32, frame.graph.scratch, &frame.workspace.extra_values, frame.values, @intCast(used), @intCast(added));
    frame.view.value_capacity = frame.values.len;

    return frame.view.value_capacity;
}

fn grow(comptime T: type, allocator: std.mem.Allocator, storage: *std.ArrayList(T), previous: []const T, used: usize, added: usize) std.mem.Allocator.Error![]T {
    if (storage.capacity == 0) {
        try storage.ensureTotalCapacity(allocator, used + added);

        storage.appendSliceAssumeCapacity(previous[0..used]);
    } else {
        storage.items.len = used;

        try storage.ensureUnusedCapacity(allocator, added);
    }

    return storage.allocatedSlice();
}

pub fn reportResolveFailure(handle: *const anyopaque, node: u32, code: []const u8, message: []const u8) zx.Error!void {
    const frame = Frame.borrow(handle);
    const tag = std.meta.stringToEnum(@FieldType(zx.Diagnostic, "code"), code) orelse unreachable;

    return frame.graph.reporter.fail(tag, frame.rows.items(.span)[node], message);
}

pub fn prepareResolveConstruction(handle: *const anyopaque, node: u32, first: u64, count: u64, object: bool) void {
    const frame = Frame.borrow(handle);
    const names = if (object) Graph.Fields.fromValues(@ptrCast(frame.rows.items(.members)[node])).names() else &.{};

    frame.base = zx.ir.TypeTable.borrow(Table, frame.graph.types.items.view());
    frame.payload = .{ .members = frame.values[@intCast(first)..][0..@intCast(count)], .names = names };
    _ = frame.scratch.open(frame.scope, frame.graph.scratch);
}

pub fn reportResolveConstruction(handle: *const anyopaque, code: []const u8, message: []const u8) zx.Error!void {
    const frame = Frame.borrow(handle);

    return frontend.reportTypeConstruction(&frame.graph.types, .{ .start = 0, .end = 0 }, code, message);
}

pub fn bindResolvedType(
    handle: *const anyopaque,
    kind: u8,
    first: u32,
    second: u32,
    label: []const u8,
    children: []const u32,
    field_names: []const []const u8,
    field_types: []const u32,
    names: []const []const u8,
) void {
    const frame = Frame.borrow(handle);
    const graph = frame.graph;
    frame.row_kind = kind;
    frame.row_first = first;
    frame.row_second = second;
    frame.row_label = label;

    const delta: zx.ir.TypeTable = .{
        .kinds = (&frame.row_kind)[0..1],
        .first = (&frame.row_first)[0..1],
        .second = (&frame.row_second)[0..1],
        .labels = (&frame.row_label)[0..1],
        .children = children,
        .field_types = field_types,
        .field_names = field_names,
        .names = names,
    };

    frame.storage = .{
        .allocator = graph.types.allocator,
        .payload = graph.types.allocator,
        .types = &graph.types.items,
        .origins = null,
        .text_mode = .Borrow,
    };

    frame.writer.init(&frame.storage, delta, no_origins);

    frame.delta = zx.ir.TypeTable.borrow(Table, delta);
    frame.write = frame.writer.request(TypeWrite, &frame.delta, &no_origins);
}

pub fn finishResolveConstruction(handle: *const anyopaque) void {
    Frame.borrow(handle).close();
}
