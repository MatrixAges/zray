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
const empty_table = zx.ir.TypeTable.borrow(Table, .{});

pub const Frame = struct {
    graph: *Graph = undefined,
    rows: Nodes.Storage.Slice = undefined,
    scope: *zx.memory.ArenaScope = undefined,
    scratch: Scratch = .{},
    graph_view: View = undefined,
    view: Session = undefined,
    tables: Tables = undefined,
    base: Table = undefined,
    payload: std.meta.Child(@FieldType(Session, "payload")) = undefined,
    pub fn bind(self: *Frame, graph: *Graph, _: *Workspace, scope: *zx.memory.ArenaScope) void {
        const rows = graph.nodes.slice();
        const kinds: []const Nodes.Kind = rows.items(.kind);
        self.graph = graph;
        self.rows = rows;
        self.scope = scope;

        comptime std.debug.assert(@sizeOf(Nodes.Kind) == @sizeOf(u8));

        self.graph_view = .{
            .kinds = zx.columns.slice(@FieldType(View, "kinds"), kinds),
            .arguments = rows.items(.argument),
            .members = rows.items(.members),
            .allowed = rows.items(.allowed),
            .fallback = rows.items(.fallback),
        };

        self.tables = .{ .base = &self.base, .delta = &empty_table };

        self.view = .{
            .frame = @ptrCast(self),
            .graph = &self.graph_view,
            .parents = graph.parents(),
            .tables = &self.tables,
            .payload = &self.payload,
        };
    }

    pub fn close(self: *Frame) void {
        if (self.scratch.previous != null) self.scratch.close(self.scope);
    }

    fn borrow(handle: *anyopaque) *Frame {
        return @ptrCast(@alignCast(handle));
    }
};

pub fn recordResolveType(handle: *anyopaque, node: u32, type_id: u32) void {
    const frame = Frame.borrow(handle);
    const graph = frame.graph;

    frame.rows.items(.argument)[node] = type_id;
    frame.rows.items(.kind)[node] = .Known;

    graph.object_revision += 1;
}

pub fn reportResolveFailure(handle: *anyopaque, node: u32, code: []const u8, message: []const u8) zx.Error!void {
    const frame = Frame.borrow(handle);
    const tag = std.meta.stringToEnum(@FieldType(zx.Diagnostic, "code"), code) orelse unreachable;

    return frame.graph.reporter.fail(tag, frame.rows.items(.span)[node], message);
}

pub fn prepareResolveConstruction(handle: *anyopaque, node: u32, object: bool) void {
    const frame = Frame.borrow(handle);
    const names = if (object) Graph.Fields.viewFromValues(@ptrCast(frame.rows.items(.members)[node])).names() else &.{};

    frame.base = zx.ir.TypeTable.borrow(Table, frame.graph.types.items.view());
    frame.payload = .{ .names = names };
    _ = frame.scratch.open(frame.scope, frame.graph.scratch);
}

pub fn reportResolveConstruction(handle: *anyopaque, code: []const u8, message: []const u8) zx.Error!void {
    const frame = Frame.borrow(handle);

    return frontend.reportTypeConstruction(&frame.graph.types, .{ .start = 0, .end = 0 }, code, message);
}

pub fn bindResolvedType(
    handle: *anyopaque,
    kind: u8,
    first: u32,
    second: u32,
    label: []const u8,
    children: []const u32,
    field_names: []const []const u8,
    field_types: []const u32,
    names: []const []const u8,
) std.mem.Allocator.Error!void {
    const frame = Frame.borrow(handle);
    const graph = frame.graph;

    const delta: zx.ir.TypeTable = .{
        .kinds = &.{kind},
        .first = &.{first},
        .second = &.{second},
        .labels = &.{label},
        .children = children,
        .field_types = field_types,
        .field_names = field_names,
        .names = names,
    };

    const empty = .{
        .ids = @as([]const u32, &.{}),
        .kinds = @as([]const u8, &.{}),
        .owners = @as([]const []const u8, &.{}),
        .members = @as([]const []const u8, &.{}),
    };

    var writer: Writer = undefined;

    writer.init(.{
        .allocator = graph.types.allocator,
        .payload = graph.types.allocator,
        .types = &graph.types.items,
        .origins = null,
        .text_mode = .Borrow,
    });

    var pending = try writer.prepare(frame.scope.active, delta, empty);

    pending.publish();
}

pub fn finishResolveConstruction(handle: *anyopaque) void {
    Frame.borrow(handle).close();
}
