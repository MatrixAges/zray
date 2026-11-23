const std = @import("std");
const zx = @import("zx");
const Graph = @import("../types.zig");
const Fields = @import("../fields/replay.zig");
const View = @import("../fields/view.zig");
const Object = @import("../construction.zig").Object;
const Closure = @import("../object_closure.zig");
const errors = @import("../../project/workflow/errors.zig");
const rule = @import("generated_rx_apply_object_construction");
const Input = std.meta.Child(rule.Input);
const Parts = std.meta.Child(@FieldType(Input, "parts"));
const Activation = std.meta.Child(@FieldType(Input, "shape"));
const Projection = std.meta.Child(@FieldType(Input, "projection"));
const Scan = std.meta.Child(@FieldType(Projection, "scan"));
const Members = std.meta.Child(@FieldType(Projection, "members"));
const Spread = struct { fields: []const []const u8, values: []const u32, root: u64, open: bool, aliases: bool };

const Frame = struct {
    graph: *Graph,
    closure: *Closure,
    object: Object,
    allocator: std.mem.Allocator,
    parts: Parts,
    members: Members = undefined,
    shape: Activation = undefined,
    fn borrow(handle: *const anyopaque) *Frame {
        return @ptrCast(@alignCast(@constCast(handle)));
    }
};

pub fn run(graph: *Graph, closure: *Closure, object: Object, root: Graph.Id, final: bool) zx.Error!void {
    var arena = std.heap.ArenaAllocator.init(graph.scratch);

    defer arena.deinit();

    var buffer: [std.heap.page_size_min]u8 = undefined;
    var scratch = std.heap.BufferFirstAllocator.init(&buffer, arena.allocator());
    var names: std.StringHashMapUnmanaged(void) = .empty;
    const allocator = scratch.allocator();
    const result = View.read(graph, root);
    const first: usize = @intCast(object.first);
    const count: usize = @intCast(object.count);
    const parts = graph.pending.construction_parts.slice();
    const columns = @import("../fields/columns.zig").borrow(std.meta.Child(@FieldType(Scan, "columns")), graph);
    const parents = graph.parents();

    var frame: Frame = .{ .graph = graph, .closure = closure, .object = object, .allocator = allocator, .parts = .{
        .explicit = parts.items(.name)[first..][0..count],
        .explicit_values = @ptrCast(parts.items(.value)[first..][0..count]),
        .fields = &.{},
        .values = &.{},
        .roots = &.{},
        .open = &.{},
        .aliases = &.{},
        .shapes = columns.kinds,
    } };

    var fields: Fields.Frame = .{ .graph = graph, .result = object.result, .span = object.span };

    const input: Input = .{
        .mode = zx.columns.view(@FieldType(Input, "mode"), result.mode),
        .parts = &frame.parts,
        .fields = @ptrCast(&fields),
        .field_view = &fields.view,
        .shape = &frame.shape,
        .projection = &.{
            .frame = @ptrCast(&frame),
            .scan = &.{
                .names = frame.parts.explicit,
                .values = frame.parts.explicit_values,
                .columns = &columns,
                .parents = @ptrCast(&parents),
                .result = @backingInt(root),
                .initial = result.names,
                .keys = @ptrCast(&names),
                .final = final,
            },
            .columns = &.{
                .fields = @ptrCast(&frame.parts.fields),
                .values = @ptrCast(&frame.parts.values),
                .roots = @ptrCast(&frame.parts.roots),
                .open = @ptrCast(&frame.parts.open),
                .aliases = @ptrCast(&frame.parts.aliases),
            },
            .members = &frame.members,
        },
    };

    rule.executeIn(allocator, &input) catch |err| switch (@as(anyerror, err)) {
        error.Overflow, error.IntegerOverflow => return error.OutOfMemory,
        else => return errors.errorSet(err),
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

pub fn proveObjectSpreadReady(handle: *const anyopaque, root: u32) std.mem.Allocator.Error!bool {
    const frame = Frame.borrow(handle);

    return frame.closure.proveRoot(frame.graph, @fromBackingInt(root), .spread);
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
