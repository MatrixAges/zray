const std = @import("std");
const zx = @import("zx");
const Graph = @import("../types.zig");
const View = @import("../fields/view.zig");
const Object = @import("../construction.zig").Object;
const Replay = @import("../object_closure/replay.zig");
const Input = Replay.ConstructionRow;
const Parts = std.meta.Child(@FieldType(Input, "parts"));
const Activation = std.meta.Child(@FieldType(Input, "shape"));
const Projection = std.meta.Child(@FieldType(Input, "projection"));
const Scan = std.meta.Child(@FieldType(Projection, "scan"));
const Buffers = std.meta.Child(@FieldType(Projection, "columns"));
const Members = std.meta.Child(@FieldType(Projection, "members"));
const Spread = struct { fields: []const []const u8, values: []const u32, root: u64, open: bool, aliases: bool };

pub const Frame = struct {
    graph: *Graph,
    object: Object,
    allocator: std.mem.Allocator,
    parts: Parts,
    members: Members = undefined,
    shape: Activation = undefined,
    names: std.StringHashMapUnmanaged(void) = .empty,
    projection: Projection = undefined,
    scan: Scan = undefined,
    buffers: Buffers = undefined,
    fn borrow(handle: *const anyopaque) *Frame {
        return @ptrCast(@alignCast(@constCast(handle)));
    }
};

pub fn openConstructionRow(handle: *const anyopaque, row: u64, root: u32, final: bool) void {
    const replay = Replay.from(handle);
    const graph = replay.graph;
    const object = graph.pending.constructions.get(@intCast(row));
    const result = View.read(graph, @fromBackingInt(root));
    const first: usize = @intCast(object.first);
    const count: usize = @intCast(object.count);
    const parts = graph.pending.construction_parts.slice();
    const columns = replay.constructions.columns;
    const frame = &replay.constructed;

    frame.* = .{ .graph = graph, .object = object, .allocator = replay.memory.open(replay.scope, graph.scratch), .parts = .{
        .explicit = parts.items(.name)[first..][0..count],
        .explicit_values = @ptrCast(parts.items(.value)[first..][0..count]),
        .fields = &.{},
        .values = &.{},
        .roots = &.{},
        .open = &.{},
        .aliases = &.{},
        .shapes = columns.kinds,
    } };

    replay.fields = .{ .graph = graph, .result = object.result, .span = object.span };

    frame.scan = .{
        .names = frame.parts.explicit,
        .values = frame.parts.explicit_values,
        .columns = columns,
        .parents = replay.constructions.parents,
        .result = root,
        .initial = result.names,
        .keys = @ptrCast(&frame.names),
        .final = final,
    };

    frame.buffers = .{
        .fields = @ptrCast(&frame.parts.fields),
        .values = @ptrCast(&frame.parts.values),
        .roots = @ptrCast(&frame.parts.roots),
        .open = @ptrCast(&frame.parts.open),
        .aliases = @ptrCast(&frame.parts.aliases),
    };

    frame.projection = .{
        .frame = @ptrCast(frame),
        .scan = &frame.scan,
        .columns = &frame.buffers,
        .members = &frame.members,
        .readiness = &replay.context,
    };

    replay.construction = .{
        .mode = zx.columns.view(@FieldType(Input, "mode"), result.mode),
        .parts = &frame.parts,
        .fields = @ptrCast(&replay.fields),
        .field_view = &replay.fields.view,
        .shape = &frame.shape,
        .projection = &frame.projection,
    };
}

pub fn reserveObjectSpreadColumns(handle: *const anyopaque) std.mem.Allocator.Error!void {
    const frame = Frame.borrow(handle);
    var spread: std.MultiArrayList(Spread) = .empty;

    try spread.resize(frame.allocator, @intCast(frame.object.count));

    const columns = spread.slice();

    frame.parts.fields = columns.items(.fields);
    frame.parts.values = columns.items(.values);
    frame.parts.roots = columns.items(.root);
    frame.parts.open = columns.items(.open);
    frame.parts.aliases = columns.items(.aliases);
}

pub fn bindObjectSpreadFields(handle: *const anyopaque, root: u32, declared: bool, inferred: bool) void {
    const frame = Frame.borrow(handle);
    const mode: View.Mode = if (declared) .Declared else if (inferred) .Inferred else .Unknown;
    const source = View.readMode(frame.graph, @fromBackingInt(root), mode);

    frame.members = .{ .names = source.names, .values = source.values };
}

pub fn registerConstructedSource(handle: *const anyopaque, index: u64, type_id: ?u32) zx.Error!u32 {
    const frame = Frame.borrow(handle);
    const part = frame.object.part(frame.graph, @intCast(index));

    return @backingInt(try frame.graph.known(@fromBackingInt(type_id.?), part.span));
}

pub fn describeConstructedTarget(handle: *const anyopaque, target: u32) void {
    const frame = Frame.borrow(handle);
    const shape = View.describe(frame.graph, frame.graph.root(@fromBackingInt(target)));

    frame.shape = .{
        .kind = @fromBackingInt(@backingInt(shape.kind)),
        .type_kind = shape.type_kind,
        .restricted = shape.restricted,
    };
}

pub fn inferConstructedField(handle: *const anyopaque, index: u64, name: []const u8, target: u32) zx.Error!void {
    const frame = Frame.borrow(handle);
    const part = frame.object.part(frame.graph, @intCast(index));
    const value = try frame.graph.field(part.value, name, frame.object.span);

    try frame.graph.expect(value, @fromBackingInt(target), frame.object.span);
}

pub fn reportObjectConstruction(handle: *const anyopaque, index: ?u64, message: []const u8) zx.Error!void {
    const frame = Frame.borrow(handle);
    const span = if (index) |row| frame.object.part(frame.graph, @intCast(row)).span else frame.object.span;

    return frame.graph.reporter.fail(.type_mismatch, span, message);
}
