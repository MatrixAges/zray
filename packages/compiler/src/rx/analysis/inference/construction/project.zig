const std = @import("std");
const zx = @import("zx");
const Graph = @import("../types.zig");
const View = @import("../fields/view.zig");
const Fields = @import("../fields/replay.zig");
const GraphColumns = @import("../fields/columns.zig");
const ObjectClosure = @import("../object_closure.zig");
const Object = @import("../construction.zig").Object;
const generated = @import("generated_object_construction_resolve");
const Input = std.meta.Child(generated.Input);
const Parts = std.meta.Child(@FieldType(Input, "parts"));
const sources = @import("generated_object_construction_sources");
const SourceInput = std.meta.Child(sources.Input);
const Source = @typeInfo(@TypeOf(sources.executeValue(undefined, undefined))).error_union.payload;
const NameSet = std.StringHashMapUnmanaged(void);
const Spread = struct { fields: []const []const u8, values: []const u32, root: u64, open: bool, aliases: bool };
const unknown_spread = "object spread source cannot be inferred from the available constraints";

pub fn propagate(graph: *Graph, closure: *ObjectClosure, object: Object, root: Graph.Id, mode: View.Mode, final: bool) zx.Error!void {
    var arena = std.heap.ArenaAllocator.init(graph.scratch);
    var buffer: [std.heap.page_size_min]u8 = undefined;
    var scratch = std.heap.BufferFirstAllocator.init(&buffer, arena.allocator());

    defer arena.deinit();

    const allocator = scratch.allocator();
    var names: NameSet = .empty;
    const parts = try project(graph, closure, allocator, object, root, mode, final, &names);

    if (names.count() == 0) return;

    const plan = generated.executeValue(allocator, &.{ .parts = &parts, .keys = @ptrCast(&names), .final = final }) catch |err| return failure(err);

    try apply(graph, object, plan.names, plan);
}

fn apply(graph: *Graph, object: Object, keys: []const []const u8, plan: anytype) zx.Error!void {
    const replay = @import("generated_object_construction_replay");
    const Replay = std.meta.Child(replay.Input);
    const Candidates = std.meta.Child(@FieldType(Replay, "plan"));

    const candidates: Candidates = .{
        .parts = plan.parts,
        .values = plan.values,
        .routes = zx.columns.slice(@FieldType(Candidates, "routes"), plan.routes),
        .receivers = zx.columns.slice(@FieldType(Candidates, "receivers"), plan.receivers),
    };

    var empty = std.heap.FixedBufferAllocator.init(&.{});
    var start: usize = 0;

    while (start < keys.len) {
        const root = graph.root(object.result);
        const target_object = Fields.borrow(std.meta.Child(@FieldType(Replay, "object")), graph, root);
        const known = graph.pending.known_types.borrow(std.meta.Child(@FieldType(Replay, "known")));
        const parents = graph.parents();

        const input: Replay = .{
            .names = keys,
            .plan = &candidates,
            .object = &target_object,
            .parents = @ptrCast(&parents),
            .known = &known,
            .start = start,
        };

        const next = zx.columns.invoke(replay.executeValue, empty.allocator(), &input) catch unreachable;
        const row: usize = @intCast(next.row);

        if (row == keys.len) return;

        const name = keys[row];
        const part_index: usize = @intCast(plan.parts[row]);
        const target = try Fields.field(graph, object.result, root, name, next.target, object.span);

        start = row + 1;

        const source: Graph.Id = if (next.register_type) |type_id|
            try graph.known(@fromBackingInt(type_id), object.part(graph, part_index).span)

        else if (next.source) |id|
            @fromBackingInt(id)
        else
            target;

        switch (next.effect) {
            .Ensure => {},
            .Bind => try graph.expect(source, target, object.span),
            .Ambiguous => return ambiguous(graph, object.span),
            .Require => {
                const entry = @import("generated_object_construction_activate");
                const shape = View.describe(graph, graph.root(target));

                const request: std.meta.Child(entry.Input) = .{
                    .route = plan.routes[row],
                    .kind = shape.kind,
                    .type_kind = shape.type_kind,
                    .restricted = shape.restricted,
                };

                switch (zx.columns.invoke(entry.executeValue, empty.allocator(), &request) catch unreachable) {
                    .Skip => {},
                    .Infer => {
                        const part = object.part(graph, part_index);
                        const value = try graph.field(part.value, name, object.span);

                        try graph.expect(value, target, object.span);
                    },
                    .Missing => return graph.reporter.fail(.type_mismatch, object.span, "constructed object is missing a required field"),
                }
            },
        }
    }
}

fn project(graph: *Graph, closure: *ObjectClosure, allocator: std.mem.Allocator, object: Object, result: Graph.Id, mode: View.Mode, final: bool, names: *NameSet) zx.Error!Parts {
    switch (mode) {
        .Invalid => return invalidObject(graph, object.span, false),
        .InvalidDeclared => return invalidObject(graph, object.span, true),
        else => {},
    }

    const result_fields = View.readMode(graph, result, mode);
    const count: usize = @intCast(object.count);
    const first: usize = @intCast(object.first);
    const part_columns = graph.pending.construction_parts.slice();
    const part_names = part_columns.items(.name)[first..][0..count];
    const part_values: []const u32 = @ptrCast(part_columns.items(.value)[first..][0..count]);
    const columns_view = GraphColumns.borrow(std.meta.Child(@FieldType(SourceInput, "columns")), graph);
    const parents = graph.parents();

    var scan: SourceInput = .{
        .names = part_names,
        .values = part_values,
        .parents = @ptrCast(&parents),
        .columns = &columns_view,
        .result = @backingInt(result),
        .first = 0,
        .keys = @ptrCast(names),
        .initial = result_fields.names,
        .final = final,
    };

    var next = try nextSpread(allocator, &scan);
    var spread: std.MultiArrayList(Spread) = .empty;

    try spread.resize(allocator, if (next.row < count) count else 0);

    const columns = spread.slice();
    const fields = columns.items(.fields);
    const values = columns.items(.values);
    const roots = columns.items(.root);
    const open = columns.items(.open);
    const aliases = columns.items(.aliases);
    const writer = @import("generated_object_construction_publish");
    const Publish = std.meta.Child(writer.Input);

    const output: std.meta.Child(@FieldType(Publish, "columns")) = .{
        .fields = @ptrCast(&fields),
        .values = @ptrCast(&values),
        .roots = @ptrCast(&roots),
        .open = @ptrCast(&open),
        .aliases = @ptrCast(&aliases),
    };

    while (next.row < count) {
        const index: usize = @intCast(next.row);
        const root: Graph.Id = @fromBackingInt(next.root);
        const part = object.part(graph, index);
        const source = View.readMode(graph, root, @fromBackingInt(@backingInt(next.mode)));
        const alias = root == result;

        const closed = switch (next.action) {
            .Closed => true,
            .Open => false,
            .Prove => try closure.proveRoot(graph, root, .spread),
            .ProveRequired => if (try closure.proveRoot(graph, root, .spread)) true else return graph.reporter.fail(.type_mismatch, part.span, unknown_spread),
            .Unknown => return graph.reporter.fail(.type_mismatch, part.span, unknown_spread),
            .Invalid => return invalidObject(graph, part.span, false),
            .InvalidDeclared => return invalidObject(graph, part.span, true),
        };

        const input: Publish = .{
            .keys = @ptrCast(names),
            .names = source.names,
            .values = source.values,
            .columns = &output,
            .row = index,
            .root = @backingInt(root),
            .open = !closed,
            .aliases = alias,
        };

        zx.columns.invoke(writer.executeValue, allocator, &input) catch |err| return failure(err);

        const start = index + 1;

        if (start == count) break;

        scan.first = start;
        next = try nextSpread(allocator, &scan);
    }

    return .{
        .explicit = part_names,
        .explicit_values = part_values,
        .fields = fields,
        .values = values,
        .roots = roots,
        .open = open,
        .aliases = aliases,
        .shapes = graph.nodes.items(.kind),
    };
}

fn nextSpread(allocator: std.mem.Allocator, input: *const SourceInput) std.mem.Allocator.Error!Source {
    return zx.columns.invoke(sources.executeValue, allocator, input) catch |err| return failure(err);
}

fn failure(err: anyerror) std.mem.Allocator.Error {
    return switch (err) {
        error.OutOfMemory, error.Overflow, error.IntegerOverflow => error.OutOfMemory,
        else => unreachable,
    };
}

fn invalidObject(graph: *Graph, span: zx.Span, declared: bool) zx.Error {
    return graph.reporter.fail(.type_mismatch, span, if (declared) "object construction requires an object source and result" else "object spread requires an object source");
}

fn ambiguous(graph: *Graph, span: zx.Span) zx.Error {
    return graph.reporter.fail(.type_mismatch, span, "multiple spread sources may provide a required field; their input types cannot be inferred uniquely");
}
