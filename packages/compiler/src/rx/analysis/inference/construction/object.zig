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
const Members = std.meta.Child(@FieldType(Projection, "members"));
const Spread = struct { fields: []const []const u8, values: []const u32, root: u64, open: bool, aliases: bool };

pub const Frame = struct {
    graph: *Graph,
    object: Object,
    allocator: std.mem.Allocator,
    spread: std.MultiArrayList(Spread) = .empty,
    parts: Parts,
    members: Members = undefined,
    shape: Activation = undefined,
    projection: Projection = undefined,
    scan: Scan = undefined,
};

pub fn openRow(replay: *Replay, row: u64, root: u32, final: bool) void {
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
        .final = final,
    };

    frame.projection = .{
        .scan = &frame.scan,
        .members = &frame.members,
        .readiness = &replay.context,
    };

    replay.construction = .{
        .mode = zx.columns.view(@FieldType(Input, "mode"), result.mode),
        .parts = &frame.parts,
        .field_view = &replay.fields.view,
        .shape = &frame.shape,
        .projection = &frame.projection,
    };
}

pub fn apply(frame: *Frame, effect: anytype, reply: anytype) zx.Error!void {
    switch (effect.object_step) {
        .ReserveSpreads => try reserveObjectSpreadColumns(frame),
        .BindSpread => bindObjectSpreadFields(frame, effect.root.?, effect.declared.?, effect.inferred.?),
        .CommitSpread => commitObjectSpread(frame, effect.row.?, effect.root.?, effect.open.?, effect.aliases.?),
        .RegisterSource => reply.id = try registerConstructedSource(frame, effect.row.?, effect.type_id.?),
        .DescribeTarget => describeConstructedTarget(frame, effect.target.?),
        .InferField => try inferConstructedField(frame, effect.row.?, effect.name.?, effect.target.?),
        .RejectConstruction => return reportObjectConstruction(frame, effect.row, effect.message.?),
        else => unreachable,
    }
}

fn reserveObjectSpreadColumns(frame: *Frame) std.mem.Allocator.Error!void {
    frame.spread = .empty;

    try frame.spread.resize(frame.allocator, @intCast(frame.object.count));

    const columns = frame.spread.slice();

    frame.parts.fields = columns.items(.fields);
    frame.parts.values = columns.items(.values);
    frame.parts.roots = columns.items(.root);
    frame.parts.open = columns.items(.open);
    frame.parts.aliases = columns.items(.aliases);
}

fn bindObjectSpreadFields(frame: *Frame, root: u32, declared: bool, inferred: bool) void {
    const mode: View.Mode = if (declared) .Declared else if (inferred) .Inferred else .Unknown;
    const source = View.readMode(frame.graph, @fromBackingInt(root), mode);

    frame.members = .{ .names = source.names, .values = source.values };
}

fn commitObjectSpread(frame: *Frame, row: u64, root: u32, open: bool, aliases: bool) void {
    const index: usize = @intCast(row);
    const columns = frame.spread.slice();

    columns.items(.root)[index] = root;
    columns.items(.open)[index] = open;
    columns.items(.aliases)[index] = aliases;
    columns.items(.fields)[index] = if (aliases) &.{} else frame.members.names;
    columns.items(.values)[index] = if (aliases) &.{} else frame.members.values;
}

fn registerConstructedSource(frame: *Frame, index: u64, type_id: u32) zx.Error!u32 {
    const part = frame.object.part(frame.graph, @intCast(index));

    return @backingInt(try frame.graph.known(@fromBackingInt(type_id), part.span));
}

fn describeConstructedTarget(frame: *Frame, target: u32) void {
    const shape = View.describe(frame.graph, frame.graph.root(@fromBackingInt(target)));

    frame.shape = .{
        .kind = @fromBackingInt(@backingInt(shape.kind)),
        .type_kind = shape.type_kind,
        .restricted = shape.restricted,
    };
}

fn inferConstructedField(frame: *Frame, index: u64, name: []const u8, target: u32) zx.Error!void {
    const part = frame.object.part(frame.graph, @intCast(index));
    const value = try frame.graph.field(part.value, name, frame.object.span);

    try frame.graph.expect(value, @fromBackingInt(target), frame.object.span);
}

fn reportObjectConstruction(frame: *Frame, index: ?u64, message: []const u8) zx.Error!void {
    const span = if (index) |row| frame.object.part(frame.graph, @intCast(row)).span else frame.object.span;

    return frame.graph.reporter.fail(.type_mismatch, span, message);
}
