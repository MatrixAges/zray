const std = @import("std");
const dsl = @import("dsl");
const generated = @import("generated_graph");
const publish = @import("generated_graph_edges");
const Tree = @import("reference/tree.zig");
const modules = @import("../modules.zig");
const memory = @import("zx").memory;
const Parameter = @typeInfo(@TypeOf(generated.executeValue)).@"fn".param_types[1].?;
pub const Input = if (@typeInfo(Parameter) == .pointer) std.meta.Child(Parameter) else Parameter;
const Issue = @typeInfo(@FieldType(Input, "issues")).pointer.child;
const Edges = std.meta.Child(publish.Input);
const Registry = std.meta.Child(@FieldType(Edges, "registry"));
const batch_size = 16;
const Link = struct { node: *const dsl.ast.Node, attribute: *const dsl.ast.Attribute };
const Result = struct { offsets: []const u64, targets: []const u64, issues: []const Issue, references: []const u64 };

comptime {
    std.debug.assert(@sizeOf(Issue) == @sizeOf(u8) and @alignOf(Issue) == @alignOf(u8));
    std.debug.assert(@backingInt(Issue.None) == 0 and @backingInt(Issue.InvalidPath) == 1 and @backingInt(Issue.Missing) == 2);
}

pub fn build(allocator: std.mem.Allocator, registered: *const modules.Registry, sources: []const modules.Source, entries: []const []const u8) std.mem.Allocator.Error!Result {
    var graph: Graph = .{ .offsets = try allocator.alloc(u64, sources.len + 1) };
    var cursor: Tree.Cursor = .{};
    var references: [batch_size][]const u8 = undefined;
    var package_allowed: [batch_size]u8 = undefined;

    const registry: Registry = .{
        .keys = registered.keys,
        .buckets = @ptrCast(&registered.buckets),
        .capacity = registered.buckets.len,
    };

    defer cursor.deinit(allocator);

    for (sources, 0..) |*source, owner| {
        if (source.indexedGraphReferences()) |indexed| {
            if (indexed.count == 0) continue;

            const values = memory.borrowIndirectTextColumn("attribute", "value", indexed.entries);
            const graph_column = memory.borrowReadColumn(bool, "graph", indexed.entries);
            const package_column = memory.borrowReadColumn(bool, "package_allowed", indexed.entries);
            const packages = memory.borrowTextColumn("specifier", source.packages);

            try graph.append(allocator, owner, .{
                .directory = std.fs.path.dirname(entries[owner]) orelse ".",
                .packages = &.{ .items = @ptrCast(&packages), .length = packages.count },
                .registry = &registry,
                .candidates = &.{
                    .references = &.{},
                    .package_allowed = &.{},
                    .first = 0,
                    .indexed = &.{
                        .values = @ptrCast(&values),
                        .graph = @ptrCast(&graph_column),
                        .packages = @ptrCast(&package_column),
                        .count = indexed.entries.len,
                    },
                },
            });

            continue;
        }

        cursor.reset(&source.node);

        const directory = std.fs.path.dirname(entries[owner]) orelse ".";
        const packages = memory.borrowTextColumn("specifier", source.packages);
        var first: usize = 0;

        while (try cursor.batch(allocator, &references, &package_allowed)) |count| {
            try graph.append(allocator, owner, .{
                .directory = directory,
                .packages = &.{ .items = @ptrCast(&packages), .length = packages.count },
                .registry = &registry,
                .candidates = &.{ .references = references[0..count], .package_allowed = package_allowed[0..count], .first = first, .indexed = null },
            });

            first += count;
        }
    }

    @memset(graph.offsets[graph.next_owner .. sources.len + 1], graph.targets.items.len);

    return .{
        .offsets = graph.offsets,
        .targets = graph.targets.items,
        .issues = @ptrCast(graph.issues.items),
        .references = graph.references.items,
    };
}

pub fn link(allocator: std.mem.Allocator, source: *const modules.Source, row: u64) std.mem.Allocator.Error!Link {
    if (source.indexedGraphReferences()) |indexed| {
        const selection = indexed.entries[@intCast(row)];

        return .{ .node = selection.node, .attribute = selection.attribute.? };
    }

    var cursor: Tree.Cursor = .{};

    defer cursor.deinit(allocator);
    cursor.reset(&source.node);

    const selection = (try cursor.seek(allocator, true, row)).?;

    return .{ .node = selection.node, .attribute = selection.attribute.? };
}

const Graph = struct {
    offsets: []u64,
    targets: std.ArrayList(u64) = .empty,
    issues: std.ArrayList(u8) = .empty,
    references: std.ArrayList(u64) = .empty,
    next_owner: usize = 0,
    fn append(self: *Graph, allocator: std.mem.Allocator, owner: usize, request: Edges) std.mem.Allocator.Error!void {
        @memset(self.offsets[self.next_owner .. owner + 1], self.targets.items.len);

        self.next_owner = owner + 1;
        var arena = std.heap.ArenaAllocator.init(allocator);

        defer arena.deinit();

        var buffer: [512]u8 = undefined;
        var scratch = std.heap.BufferFirstAllocator.init(&buffer, arena.allocator());

        const result = publish.executeValue(scratch.allocator(), &request) catch |err| switch (@as(anyerror, err)) {
            error.OutOfMemory => return error.OutOfMemory,
            else => unreachable,
        };

        try self.targets.appendSlice(allocator, result.targets);
        try self.issues.appendSlice(allocator, result.issues);
        try self.references.appendSlice(allocator, result.references);
    }
};
