const std = @import("std");
const dsl = @import("dsl");
const generated = @import("generated_graph");
const publish = @import("generated_graph_edges");
const dependency = @import("reference.zig");
const modules = @import("../modules.zig");
const memory = @import("zx").memory;
const Parameter = @typeInfo(@TypeOf(generated.executeValue)).@"fn".param_types[1].?;
pub const Input = if (@typeInfo(Parameter) == .pointer) std.meta.Child(Parameter) else Parameter;
const Issue = @typeInfo(@FieldType(Input, "issues")).pointer.child;
const Batch = std.meta.Child(publish.Input);
const Edges = std.meta.Child(@FieldType(Batch, "edges"));
const Registry = std.meta.Child(@FieldType(Edges, "registry"));
const inline_path_bytes = 512;
const batch_size = 16;
const Link = struct { node: *const dsl.ast.Node, attribute: *const dsl.ast.Attribute };
const Result = struct { offsets: []const u64, targets: []const u64, issues: []const Issue, references: []const u64 };

comptime {
    std.debug.assert(@sizeOf(Issue) == @sizeOf(u8) and @alignOf(Issue) == @alignOf(u8));
    std.debug.assert(@backingInt(Issue.None) == 0 and @backingInt(Issue.InvalidPath) == 1 and @backingInt(Issue.Missing) == 2);
}

pub fn build(allocator: std.mem.Allocator, registered: *const modules.Registry, sources: []const modules.Source, entries: []const []const u8) std.mem.Allocator.Error!Result {
    var graph: Graph = .{ .offsets = try allocator.alloc(u64, sources.len + 1) };
    var iterator: dependency.Iterator = .{};
    var inline_path: [inline_path_bytes]u8 = undefined;
    var path: []u8 = &inline_path;
    var references: [batch_size][]const u8 = undefined;
    var package_allowed: [batch_size]u8 = undefined;

    const registry: Registry = .{
        .keys = registered.keys,
        .buckets = @ptrCast(&registered.buckets),
        .capacity = registered.buckets.len,
    };

    defer iterator.deinit(allocator);

    for (sources, 0..) |*source, owner| {
        if (source.indexedGraphReferences()) |indexed| {
            if (indexed.count == 0) continue;

            const values = memory.borrowIndirectTextColumn("attribute", "value", indexed.entries);
            const graph_column = memory.borrowReadColumn(bool, "graph", indexed.entries);
            const package_column = memory.borrowReadColumn(bool, "package_allowed", indexed.entries);
            const packages = memory.borrowTextColumn("specifier", source.packages);

            try graph.append(allocator, owner, &path, indexed.count, .{
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
                .workspace = undefined,
                .output = undefined,
                .allocator = undefined,
            });

            continue;
        }

        iterator.reset(&source.node, source.references);

        var next = try iterator.next(allocator, true);

        if (next == null) continue;

        const directory = std.fs.path.dirname(entries[owner]) orelse ".";
        const packages = memory.borrowTextColumn("specifier", source.packages);
        var first: usize = 0;

        while (next != null) {
            var count: usize = 0;

            while (next) |selection| {
                references[count] = selection.attribute.?.value;
                package_allowed[count] = @intFromBool(selection.package_allowed);
                count += 1;
                next = try iterator.next(allocator, true);

                if (count == batch_size) break;
            }

            try graph.append(allocator, owner, &path, count, .{
                .directory = directory,
                .packages = &.{ .items = @ptrCast(&packages), .length = packages.count },
                .registry = &registry,
                .candidates = &.{ .references = references[0..count], .package_allowed = package_allowed[0..count], .first = first, .indexed = null },
                .workspace = undefined,
                .output = undefined,
                .allocator = undefined,
            });

            first += count;
        }
    }

    const empty = memory.borrowTextColumn("specifier", @as([]const @import("frontend").project.Package, &.{}));

    try graph.append(allocator, sources.len, &path, 0, .{
        .directory = "",
        .packages = &.{ .items = @ptrCast(&empty), .length = 0 },
        .registry = &registry,
        .candidates = &.{ .references = &.{}, .package_allowed = &.{}, .first = 0, .indexed = null },
        .workspace = undefined,
        .output = undefined,
        .allocator = undefined,
    });

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

    var iterator: dependency.Iterator = .{};
    var remaining = row;

    defer iterator.deinit(allocator);
    iterator.reset(&source.node, source.references);

    while (try iterator.next(allocator, true)) |selection| {
        if (remaining == 0) return .{ .node = selection.node, .attribute = selection.attribute.? };

        remaining -= 1;
    }

    unreachable;
}

const Graph = struct {
    offsets: []u64,
    targets: std.ArrayList(u64) = .empty,
    issues: std.ArrayList(u8) = .empty,
    references: std.ArrayList(u64) = .empty,
    next_owner: usize = 0,
    fn append(self: *Graph, allocator: std.mem.Allocator, owner: usize, path: *[]u8, capacity: usize, request: Edges) std.mem.Allocator.Error!void {
        var input = request;

        try self.targets.ensureUnusedCapacity(allocator, capacity);
        try self.issues.ensureUnusedCapacity(allocator, capacity);
        try self.references.ensureUnusedCapacity(allocator, capacity);

        const targets = self.targets.unusedCapacitySlice()[0..capacity];
        const issues = self.issues.unusedCapacitySlice()[0..capacity];
        const references = self.references.unusedCapacitySlice()[0..capacity];
        var scratch = std.heap.FixedBufferAllocator.init(&.{});

        input.workspace = &.{ .bytes = path.*, .target = @ptrCast(path), .start = 0 };
        input.output = &.{ .targets = @ptrCast(&targets), .issues = @ptrCast(&issues), .references = @ptrCast(&references) };
        input.allocator = @ptrCast(&allocator);

        const written: usize = @intCast(publish.executeValue(scratch.allocator(), &.{
            .offsets = &.{ .offsets = @ptrCast(&self.offsets), .first = self.next_owner, .end = owner + 1, .edge = self.targets.items.len },
            .edges = &input,
        }) catch |err| switch (@as(anyerror, err)) {
            error.OutOfMemory => return error.OutOfMemory,
            else => unreachable,
        });

        self.next_owner = owner + 1;
        self.targets.items.len += written;
        self.issues.items.len += written;
        self.references.items.len += written;
    }
};
