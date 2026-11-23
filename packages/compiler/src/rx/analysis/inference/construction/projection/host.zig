const std = @import("std");
const zx = @import("zx");
const Graph = @import("../../types.zig");
const View = @import("../../fields/view.zig");
const GraphColumns = @import("../../fields/columns.zig");
const Closure = @import("../../object_closure.zig");
const Object = @import("../../construction.zig").Object;
const errors = @import("../../../project/workflow/errors.zig");
const rule = @import("generated_rx_project_object_spreads");
const Input = std.meta.Child(rule.Input);
const Scan = std.meta.Child(@FieldType(Input, "scan"));
const Columns = std.meta.Child(@FieldType(Input, "columns"));
const Members = std.meta.Child(@FieldType(Input, "members"));
const Spread = struct { fields: []const []const u8, values: []const u32, root: u64, open: bool, aliases: bool };

pub const NameSet = std.StringHashMapUnmanaged(void);

const Frame = struct {
    graph: *Graph,
    closure: *Closure,
    object: Object,
    allocator: std.mem.Allocator,
    members: Members = undefined,
    fields: [][]const []const u8 = &.{},
    values: [][]const u32 = &.{},
    roots: []u64 = &.{},
    open: []bool = &.{},
    aliases: []bool = &.{},
    fn from(handle: *const anyopaque) *Frame {
        return @ptrCast(@alignCast(@constCast(handle)));
    }
};

pub fn run(comptime Parts: type, graph: *Graph, closure: *Closure, allocator: std.mem.Allocator, object: Object, result: Graph.Id, final: bool, names: *NameSet) zx.Error!Parts {
    const result_fields = View.read(graph, result);

    switch (result_fields.mode) {
        .Invalid => return invalidObject(graph, object.span, false),
        .InvalidDeclared => return invalidObject(graph, object.span, true),
        else => {},
    }

    const first: usize = @intCast(object.first);
    const count: usize = @intCast(object.count);
    const parts = graph.pending.construction_parts.slice();
    const part_names = parts.items(.name)[first..][0..count];
    const part_values: []const u32 = @ptrCast(parts.items(.value)[first..][0..count]);
    const columns = GraphColumns.borrow(std.meta.Child(@FieldType(Scan, "columns")), graph);
    const parents = graph.parents();
    var frame: Frame = .{ .graph = graph, .closure = closure, .object = object, .allocator = allocator };

    const input: Input = .{
        .frame = @ptrCast(&frame),
        .scan = &.{
            .names = part_names,
            .values = part_values,
            .parents = @ptrCast(&parents),
            .columns = &columns,
            .result = @backingInt(result),
            .keys = @ptrCast(names),
            .initial = result_fields.names,
            .final = final,
        },
        .columns = &.{
            .fields = @ptrCast(&frame.fields),
            .values = @ptrCast(&frame.values),
            .roots = @ptrCast(&frame.roots),
            .open = @ptrCast(&frame.open),
            .aliases = @ptrCast(&frame.aliases),
        },
        .members = &frame.members,
    };

    rule.executeIn(allocator, &input) catch |err| switch (@as(anyerror, err)) {
        error.Overflow, error.IntegerOverflow => return error.OutOfMemory,
        else => return errors.errorSet(err),
    };

    return .{
        .explicit = part_names,
        .explicit_values = part_values,
        .fields = frame.fields,
        .values = frame.values,
        .roots = frame.roots,
        .open = frame.open,
        .aliases = frame.aliases,
        .shapes = graph.nodes.items(.kind),
    };
}

pub fn reserveObjectSpreadColumns(handle: *const anyopaque) std.mem.Allocator.Error!void {
    const frame = Frame.from(handle);
    var spread: std.MultiArrayList(Spread) = .empty;

    try spread.resize(frame.allocator, @intCast(frame.object.count));

    const columns = spread.slice();

    frame.fields = columns.items(.fields);
    frame.values = columns.items(.values);
    frame.roots = columns.items(.root);
    frame.open = columns.items(.open);
    frame.aliases = columns.items(.aliases);
}

pub fn bindObjectSpreadFields(handle: *const anyopaque, root: u32, declared: bool, inferred: bool) void {
    const frame = Frame.from(handle);
    const mode: View.Mode = if (declared) .Declared else if (inferred) .Inferred else .Unknown;
    const source = View.readMode(frame.graph, @fromBackingInt(root), mode);

    frame.members = .{ .names = source.names, .values = source.values };
}

pub fn proveObjectSpreadReady(handle: *const anyopaque, root: u32) std.mem.Allocator.Error!bool {
    const frame = Frame.from(handle);

    return frame.closure.proveRoot(frame.graph, @fromBackingInt(root), .spread);
}

pub fn rejectUnknownObjectSpread(handle: *const anyopaque, row: u64) zx.Error!void {
    const frame = Frame.from(handle);
    const part = frame.object.part(frame.graph, @intCast(row));

    return frame.graph.reporter.fail(.type_mismatch, part.span, "object spread source cannot be inferred from the available constraints");
}

pub fn rejectInvalidObjectSpread(handle: *const anyopaque, row: u64, declared: bool) zx.Error!void {
    const frame = Frame.from(handle);
    const part = frame.object.part(frame.graph, @intCast(row));

    return invalidObject(frame.graph, part.span, declared);
}

fn invalidObject(graph: *Graph, span: zx.Span, declared: bool) zx.Error {
    return graph.reporter.fail(.type_mismatch, span, if (declared) "object construction requires an object source and result" else "object spread requires an object source");
}
