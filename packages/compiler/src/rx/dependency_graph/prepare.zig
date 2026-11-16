const std = @import("std");
const dsl = @import("dsl");
const generated = @import("generated_graph");
const edge = @import("generated_graph_edge");
const dependency = @import("reference.zig");
const modules = @import("../modules.zig");
const memory = @import("zxc_standard").memory;
const Parameter = @typeInfo(@TypeOf(generated.executeValue)).@"fn".param_types[1].?;
pub const Input = if (@typeInfo(Parameter) == .pointer) std.meta.Child(Parameter) else Parameter;
const Issue = @typeInfo(@FieldType(Input, "issues")).pointer.child;
const Resolved = @typeInfo(@TypeOf(edge.executeValue(undefined, undefined))).error_union.payload;
const Edge = if (@typeInfo(Resolved) == .pointer) std.meta.Child(Resolved) else Resolved;
const inline_path_bytes = 512;
const Link = struct { node: *const dsl.ast.Node, attribute: *const dsl.ast.Attribute };
const Result = struct { offsets: []const u64, targets: []const u64, issues: []const Issue, links: []const Link };

pub fn build(allocator: std.mem.Allocator, registered: *const modules.Registry, sources: []const modules.Source, entries: []const []const u8) std.mem.Allocator.Error!Result {
    const offsets = try allocator.alloc(u64, sources.len + 1);
    var targets: std.ArrayList(u64) = .empty;
    var issues: std.ArrayList(Issue) = .empty;
    var links: std.ArrayList(Link) = .empty;
    var references: dependency.Iterator = .{};
    var inline_path: [inline_path_bytes]u8 = undefined;
    var path: []u8 = &inline_path;

    const registry: std.meta.Child(@FieldType(std.meta.Child(edge.Input), "registry")) = .{
        .keys = registered.keys,
        .buckets = @ptrCast(&registered.buckets),
        .capacity = registered.buckets.len,
    };

    defer references.deinit(allocator);

    for (sources, 0..) |*source, owner| {
        offsets[owner] = targets.items.len;

        references.reset(&source.node, source.references);

        var next = try references.next(allocator, true);

        if (next == null) continue;

        const directory = std.fs.path.dirname(entries[owner]) orelse ".";
        const packages = memory.borrowTextColumn("specifier", source.packages);

        while (next) |selection| : (next = try references.next(allocator, true)) {
            const attribute = selection.attribute orelse unreachable;

            const input: std.meta.Child(edge.Input) = .{
                .directory = directory,
                .reference = attribute.value,
                .package_allowed = selection.package_allowed,
                .packages = &.{ .items = @ptrCast(&packages), .length = packages.count },
                .registry = &registry,
                .workspace = undefined,
            };

            var target = resolve(input, &path);

            if (target.required > path.len) {
                path = try allocator.alloc(u8, std.math.cast(usize, target.required) orelse return error.OutOfMemory);
                target = resolve(input, &path);
            }

            if (!target.included) continue;
            try targets.append(allocator, target.target);
            try issues.append(allocator, target.issue);
            try links.append(allocator, .{ .node = selection.node, .attribute = attribute });
        }
    }

    offsets[sources.len] = targets.items.len;

    return .{ .offsets = offsets, .targets = targets.items, .issues = issues.items, .links = links.items };
}

fn resolve(request: std.meta.Child(edge.Input), path: *const []u8) Edge {
    var input = request;
    var storage: [@sizeOf(Edge)]u8 align(@alignOf(Edge)) = undefined;
    var scratch = std.heap.FixedBufferAllocator.init(&storage);

    input.workspace = &.{ .bytes = path.*, .target = @ptrCast(path) };

    const resolved = edge.executeValue(scratch.allocator(), &input) catch unreachable;

    return if (comptime @typeInfo(Resolved) == .pointer) resolved.* else resolved;
}
