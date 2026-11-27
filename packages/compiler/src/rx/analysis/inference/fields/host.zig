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

pub const Frame = struct {
    graph: *Graph,
    target: Graph.Id,
    root: Graph.Id,
    span: zx.Span,
    site: Site = undefined,
    receiver: Receiver = undefined,
    members: Members = undefined,
    inferred: Graph.Fields = .{},
    pub fn bind(self: *Frame) View.Shape {
        const graph = self.graph;
        const shape = View.describe(graph, self.root);
        const types = &graph.types.items;
        const known = shape.kind == .Known;
        const argument = if (known) types.first.items[shape.argument] else 0;

        self.inferred = if (shape.kind == .Object)
            graph.mutableFields(graph.nodes.items(.members)[@backingInt(self.root)])

        else
            Graph.Fields{};

        const layout = Graph.Fields.layout(self.inferred);

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
            .prefix = layout.prefix,
            .capacity = layout.capacity,
            .published = layout.published,
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
    const outcome = zx.columns.invoke(rule.executeValue, empty.allocator(), &input) catch |err| return errors.errorSet(err);

    if (outcome.revised) graph.revision += 1;

    return @fromBackingInt(outcome.value);
}

pub fn addFieldNode(handle: *anyopaque) zx.Error!u32 {
    const frame = Frame.borrow(handle);

    return @backingInt(try frame.graph.add(.unknown, frame.span));
}

pub fn appendFieldMember(handle: *anyopaque, name: []const u8, capacity: ?u64) zx.Error!u32 {
    const frame = Frame.borrow(handle);
    const graph = frame.graph;
    const value = try graph.add(.unknown, frame.span);
    const owned_name = try graph.types.allocator.dupe(u8, name);
    const existing = frame.inferred;
    const count = existing.len + 1;
    const next = try Graph.Fields.grow(&graph.field_buffers, graph.allocator, existing, count, if (capacity) |size| std.math.cast(usize, size) orelse return error.OutOfMemory else null);

    next.set(existing.len, owned_name, value);
    Nodes.setShape(graph.nodes.slice(), @backingInt(frame.root), .{ .object = next.view() });

    return @backingInt(value);
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
