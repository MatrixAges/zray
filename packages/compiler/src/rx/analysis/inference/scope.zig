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

    return @import("scope/read.zig").run(graph, rows, facts, name, identifier, span);
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

    const value = try graph.add(.unknown, span);

    errdefer graph.nodes.len -= 1;

    try graph.pending.binding_lookups.append(allocator, .{ .candidates = candidates.items, .value = value, .span = span });

    return value;
}
