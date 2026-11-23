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
const Append = std.meta.Child(@FieldType(Site, "append"));
const Columns = std.meta.Child(@FieldType(Append, "columns"));
const Shape = std.meta.Child(@FieldType(Append, "shape"));

pub const Frame = struct {
    graph: *Graph,
    target: Graph.Id,
    root: Graph.Id,
    span: zx.Span,
    site: Site = undefined,
    receiver: Receiver = undefined,
    members: Members = undefined,
    inferred: Graph.Fields = undefined,
    append: Append = undefined,
    writable: Nodes.Writable = undefined,
    columns: Columns = undefined,
    shape: Shape = undefined,
    names: [][]const u8 = undefined,
    values: []u32 = undefined,
    pub fn bind(self: *Frame) View.Shape {
        const graph = self.graph;
        const shape = View.describe(graph, self.root);
        const types = &graph.types.items;
        const known = shape.kind == .Known;
        const argument = if (known) types.first.items[shape.argument] else 0;

        self.inferred = if (shape.kind == .Object)
            Graph.Fields.fromValues(@ptrCast(graph.nodes.items(.members)[@backingInt(self.root)]))

        else
            .{};

        self.members = if (known and shape.type_kind == @backingInt(@as(std.meta.Tag(zx.ir.Type), .object))) members: {
            const count = types.second.items[shape.argument];

            break :members .{
                .names = types.field_names.items[argument..][0..count],
                .values = types.field_types.items[argument..][0..count],
            };
        } else .{ .names = self.inferred.names(), .values = @ptrCast(self.inferred.values()) };

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
            .append = &self.append,
        };

        return shape;
    }
    fn borrow(handle: *const anyopaque) *Frame {
        return @ptrCast(@alignCast(@constCast(handle)));
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

pub fn reserveFieldAppend(handle: *const anyopaque, name: []const u8) zx.Error!void {
    const frame = Frame.borrow(handle);
    const graph = frame.graph;
    const index = frame.inferred.len;
    const result = try graph.add(.unknown, frame.span);
    const retained = try graph.types.allocator.dupe(u8, name);
    const fields = try frame.inferred.extend(graph.allocator, index + 1);
    frame.writable = Nodes.writable(graph.nodes.slice());
    frame.names = fields.nameColumn();
    frame.values = @ptrCast(fields.valueColumn());
    frame.columns = frame.writable.borrow(Columns);
    frame.shape = .{ .kind = @backingInt(Nodes.Kind.Object), .argument = 0, .members = frame.values };

    frame.append = .{
        .parent = @backingInt(frame.root),
        .columns = &frame.columns,
        .shape = &frame.shape,
        .names = @ptrCast(&frame.names),
        .values = @ptrCast(&frame.values),
        .position = index,
        .name = retained,
        .value = @backingInt(result),
    };
}

pub fn publishFieldRevision(handle: *const anyopaque) void {
    Frame.borrow(handle).graph.revision += 1;
}

pub fn registerFieldType(handle: *const anyopaque, type_id: u32) zx.Error!u32 {
    const frame = Frame.borrow(handle);

    return @backingInt(try frame.graph.known(@fromBackingInt(type_id), frame.span));
}

pub fn requireFieldList(handle: *const anyopaque) zx.Error!void {
    const frame = Frame.borrow(handle);

    _ = try frame.graph.payload(frame.target, .list, frame.span);
}

pub fn deferFieldLength(handle: *const anyopaque) zx.Error!u32 {
    const frame = Frame.borrow(handle);
    const graph = frame.graph;
    const result = try graph.add(.unknown, frame.span);

    try graph.pending.lengths.append(graph.pending.allocator, .{ .target = frame.target, .value = result, .span = frame.span });

    return @backingInt(result);
}

pub fn rejectFieldAccess(handle: *const anyopaque, message: []const u8) zx.Error!void {
    const frame = Frame.borrow(handle);

    return frame.graph.reporter.fail(.type_mismatch, frame.span, message);
}
