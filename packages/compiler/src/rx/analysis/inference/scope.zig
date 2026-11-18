const std = @import("std");
const zx = @import("zx");
const Graph = @import("types.zig");
const bindings = @import("bindings.zig");
const rules = @import("bindings/rules.zig");
const paths = @import("frontend").binding_path;
const generated = @import("rx_options").generated_graph;
const collisions = @import("scope/collisions.zig");
pub const Binding = struct { name: []const u8, value: Graph.Id, span: zx.Span = .{ .start = 0, .end = 0 } };
pub const Storage = std.MultiArrayList(Binding);
pub const appendFrom = zx.columns.appendRows;

pub const Reference = struct {
    value: ?Graph.Id = null,
    implicit_input: bool = false,
    refined: bool = false,
};

pub fn rooted(names: []const []const u8, path: paths.Path, implicit_input: bool) bool {
    if (names.len == 0 and !implicit_input) return false;

    if (comptime generated) {
        const rule = @import("generated_rx_scope_rooted");
        var empty = std.heap.FixedBufferAllocator.init(&.{});

        return rule.executeValue(empty.allocator(), .{ .names = names, .path = path.text, .implicit_input = implicit_input }) catch unreachable;
    }

    if (implicit_input and path.rooted("$in")) return true;
    for (names) |name| if (path.rooted(name)) return true;

    return false;
}

pub fn read(graph: *Graph, rows: Storage.Slice, facts: []const []const u8, name: []const u8, identifier: bool, span: zx.Span) zx.Error!Reference {
    if (comptime !generated) return .{
        .value = try lookupSeed(graph, rows, name, span),
        .implicit_input = identifier and std.mem.eql(u8, name, "$in"),
        .refined = for (facts) |fact| {
            if (std.mem.eql(u8, fact, name)) break true;
        } else false,
    };

    const entry = @import("generated_rx_scope_lookup");
    const Input = std.meta.Child(entry.Input);
    const parents: []u32 = graph.parents();
    const topology: std.meta.Child(@FieldType(Input, "topology")) = .{ .graph = &rules.view(entry, graph), .parents = @ptrCast(&parents) };
    const active: std.meta.Child(@FieldType(Input, "active")) = .{ .names = rows.items(.name), .values = @ptrCast(rows.items(.value)) };
    var candidates: zx.memory.U32Scratch = .{ .allocator = graph.pending.allocator };

    errdefer candidates.deinit();

    const lengths: zx.memory.ColumnLengths = &.{&candidates.backing.items.len};

    const query: Input = .{
        .topology = &topology,
        .active = &active,
        .name = name,
        .start = 0,
        .facts = facts,
        .identifier = identifier,
        .candidates = &.{ .scratch = @ptrCast(&candidates), .values = @ptrCast(&candidates.items), .lengths = @ptrCast(&lengths) },
    };

    var empty = std.heap.FixedBufferAllocator.init(&.{});

    const result = zx.columns.invoke(entry.executeValue, empty.allocator(), &query) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };

    const value: ?Graph.Id = if (candidates.backing.items.len != 0)
        try bindings.lookup(graph, @ptrCast(candidates.backing.items), span)

    else if (result.value) |id| @fromBackingInt(id) else null;

    return .{ .value = value, .implicit_input = result.implicit_input, .refined = result.refined };
}

pub fn check(graph: *Graph, rows: Storage.Slice, end: usize, binding: Binding, message: []const u8) zx.Error!void {
    if (end == 0) return;
    if (comptime generated) return collisions.check(graph, rows, end, binding, message);

    const names = rows.items(.name)[0..end];
    const values = rows.items(.value)[0..end];

    for (names, values) |name, value| {
        if (!paths.overlaps(name, binding.name)) continue;
        try bindings.distinct(graph, value, binding.value, binding.span, message, rules.pair(graph, value, binding.value, false));
    }
}

pub fn publishParallel(graph: *Graph, active_scope: *Storage, allocator: std.mem.Allocator, saved: Storage.Slice) zx.Error!void {
    const message = "Parallel result binding paths must not overlap";

    if (!generated) {
        for (0..saved.len) |index| {
            const binding = saved.get(index);

            try check(graph, saved, index, binding, message);
            try active_scope.append(allocator, binding);
        }

        return;
    }

    if (saved.len < 2) return appendFrom(active_scope, allocator, saved, 0);
    try collisions.parallel(graph, active_scope, allocator, saved, message);
}

fn lookupSeed(graph: *Graph, rows: Storage.Slice, name: []const u8, span: zx.Span) zx.Error!?Graph.Id {
    const allocator = graph.pending.allocator;
    var selected: ?Graph.Id = null;
    var candidates: std.ArrayList(Graph.Id) = .empty;

    errdefer candidates.deinit(allocator);

    for (rows.items(.name), rows.items(.value)) |path, value| {
        if (!std.mem.eql(u8, path, name) or bindings.isVoid(graph, value)) continue;

        if (selected) |previous| {
            if (candidates.items.len == 0) {
                try candidates.ensureTotalCapacityPrecise(allocator, 2);

                candidates.appendAssumeCapacity(previous);
            }

            try candidates.append(allocator, value);
        }

        selected = value;
    }

    if (candidates.items.len == 0) return selected;

    return try bindings.lookup(graph, candidates.items, span);
}
