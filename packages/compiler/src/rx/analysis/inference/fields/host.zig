const std = @import("std");
const zx = @import("zx");
const Graph = @import("../types.zig");
const Nodes = @import("../nodes.zig");
const View = @import("view.zig");
const errors = @import("../../project/workflow/errors.zig");
const rule = @import("generated_rx_read_field");
const Input = std.meta.Child(rule.Input);
const Site = std.meta.Child(@FieldType(Input, "site"));
const Receiver = std.meta.Child(@FieldType(Site, "receiver"));
const Members = std.meta.Child(@FieldType(Site, "members"));
const Storage = std.meta.Child(@FieldType(Site, "storage"));
const Columns = std.meta.Child(@FieldType(Site, "columns"));

pub const Frame = struct {
    graph: *Graph,
    target: Graph.Id,
    root: Graph.Id,
    span: zx.Span,
    site: Site = undefined,
    receiver: Receiver = undefined,
    members: Members = undefined,
    resize: Graph.Fields.Resize = undefined,
    storage: Storage = undefined,
    writable: Nodes.Writable = undefined,
    columns: Columns = undefined,
    revision: []u64 = undefined,
    pub fn bind(self: *Frame) View.Shape {
        const graph = self.graph;
        const shape = View.describe(graph, self.root);
        const types = &graph.types.items;
        const known = shape.kind == .Known;
        const argument = if (known) types.first.items[shape.argument] else 0;

        const inferred = if (shape.kind == .Object)
            graph.mutableFields(graph.nodes.items(.members)[@backingInt(self.root)])

        else
            Graph.Fields{};

        self.resize = .{ .buffers = &graph.field_buffers, .allocator = graph.allocator, .fields = inferred };
        self.storage = self.resize.borrow(Storage);
        self.revision = (&graph.revision)[0..1];

        self.members = if (known and shape.type_kind == @backingInt(@as(std.meta.Tag(zx.ir.Type), .object))) members: {
            const count = types.second.items[shape.argument];

            break :members .{
                .names = types.field_names.items[argument..][0..count],
                .values = types.field_types.items[argument..][0..count],
            };
        } else .{ .names = self.storage.source_names, .values = self.storage.source_values };

        self.receiver = .{
            .kind = zx.columns.view(@FieldType(Receiver, "kind"), shape.kind),
            .type_kind = shape.type_kind,
            .type_argument = argument,
            .restricted = shape.restricted,
        };

        self.site = .{
            .frame = @ptrCast(self),
            .receiver = &self.receiver,
            .members = &self.members,
            .storage = &self.storage,
            .allocator = @ptrCast(&graph.types.allocator),
            .columns = &self.columns,
            .parent = @backingInt(self.root),
            .object_kind = @backingInt(Nodes.Kind.Object),
            .revision = @ptrCast(&self.revision),
        };

        return shape;
    }
    fn borrow(handle: *anyopaque) *Frame {
        return @ptrCast(@alignCast(handle));
    }
};

pub fn read(graph: *Graph, target: Graph.Id, root: Graph.Id, name: []const u8, span: zx.Span, open: bool) zx.Error!Graph.Id {
    var frame: Frame = .{ .graph = graph, .target = target, .root = root, .span = span };
    _ = frame.bind();

    const input: Input = .{ .site = &frame.site, .name = name, .open = open };
    var empty = std.heap.FixedBufferAllocator.init(&.{});
    const value = rule.executeIn(empty.allocator(), &input) catch |err| return errors.errorSet(err);

    return @fromBackingInt(value);
}

pub fn addFieldNode(handle: *anyopaque) zx.Error!u32 {
    const frame = Frame.borrow(handle);
    const graph = frame.graph;
    const result = try graph.add(.unknown, frame.span);
    frame.writable = Nodes.writable(graph.nodes.slice());
    frame.columns = frame.writable.borrow(Columns);

    return @backingInt(result);
}

pub fn registerFieldType(handle: *anyopaque, type_id: u32) zx.Error!u32 {
    const frame = Frame.borrow(handle);

    return @backingInt(try frame.graph.known(@fromBackingInt(type_id), frame.span));
}

pub fn requireFieldList(handle: *anyopaque) zx.Error!void {
    const frame = Frame.borrow(handle);

    _ = try frame.graph.payload(frame.target, .list, frame.span);
}

pub fn appendLengthProjection(handle: *anyopaque, value: u32) std.mem.Allocator.Error!void {
    const frame = Frame.borrow(handle);
    const pending = &frame.graph.pending;

    try pending.lengths.append(pending.allocator, .{
        .target = frame.target,
        .value = @fromBackingInt(value),
        .span = frame.span,
    });
}

pub fn rejectFieldAccess(handle: *anyopaque, message: []const u8) zx.Error!void {
    const frame = Frame.borrow(handle);

    return frame.graph.reporter.fail(.type_mismatch, frame.span, message);
}
