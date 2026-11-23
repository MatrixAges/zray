const std = @import("std");
const zx = @import("zx");
const Graph = @import("../../types.zig");
const View = @import("../../fields/view.zig");
const Fields = @import("../../fields/replay.zig");
const Object = @import("../../construction.zig").Object;
const errors = @import("../../../project/workflow/errors.zig");
const rule = @import("generated_rx_apply_construction_fields");
const Input = std.meta.Child(rule.Input);
const Candidates = std.meta.Child(@FieldType(Input, "plan"));
const Shape = std.meta.Child(@FieldType(Input, "shape"));

const Frame = struct {
    graph: *Graph,
    object: Object,
    shape: Shape = undefined,
    fn from(handle: *const anyopaque) *Frame {
        return @ptrCast(@alignCast(@constCast(handle)));
    }
};

pub fn run(graph: *Graph, object: Object, plan: anytype) zx.Error!void {
    if (plan.names.len == 0) return;

    var frame: Frame = .{ .graph = graph, .object = object };
    var fields: Fields.Frame = .{ .graph = graph, .result = object.result, .span = object.span };

    fields.bind();

    const input: Input = .{
        .frame = @ptrCast(&frame),
        .fields = @ptrCast(&fields),
        .field_view = &fields.view,
        .names = plan.names,
        .plan = &.{
            .parts = plan.parts,
            .values = plan.values,
            .routes = zx.columns.slice(@FieldType(Candidates, "routes"), plan.routes),
            .receivers = zx.columns.slice(@FieldType(Candidates, "receivers"), plan.receivers),
        },
        .shape = &frame.shape,
    };

    var empty = std.heap.FixedBufferAllocator.init(&.{});

    rule.executeIn(empty.allocator(), &input) catch |err| return errors.errorSet(err);
}

pub fn registerConstructedSource(handle: *const anyopaque, index: u64, type_id: ?u32) zx.Error!u32 {
    const frame = Frame.from(handle);
    const part = frame.object.part(frame.graph, @intCast(index));

    return @backingInt(try frame.graph.known(@fromBackingInt(type_id.?), part.span));
}

pub fn describeConstructedTarget(handle: *const anyopaque, target: u32) void {
    const frame = Frame.from(handle);
    const shape = View.describe(frame.graph, frame.graph.root(@fromBackingInt(target)));

    frame.shape = .{
        .kind = @fromBackingInt(@backingInt(shape.kind)),
        .type_kind = shape.type_kind,
        .restricted = shape.restricted,
    };
}

pub fn inferConstructedField(handle: *const anyopaque, index: u64, name: []const u8, target: u32) zx.Error!void {
    const frame = Frame.from(handle);
    const part = frame.object.part(frame.graph, @intCast(index));
    const value = try frame.graph.field(part.value, name, frame.object.span);

    try frame.graph.expect(value, @fromBackingInt(target), frame.object.span);
}

pub fn rejectMissingConstructedField(handle: *const anyopaque) zx.Error!void {
    const frame = Frame.from(handle);

    return frame.graph.reporter.fail(.type_mismatch, frame.object.span, "constructed object is missing a required field");
}

pub fn rejectAmbiguousConstructedField(handle: *const anyopaque) zx.Error!void {
    const frame = Frame.from(handle);

    return frame.graph.reporter.fail(.type_mismatch, frame.object.span, "multiple spread sources may provide a required field; their input types cannot be inferred uniquely");
}
