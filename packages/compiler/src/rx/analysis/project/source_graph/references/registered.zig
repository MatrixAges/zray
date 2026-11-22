const std = @import("std");
const builtin = @import("builtin");
const rx = @import("rx");
const zx = @import("zx");
const project = @import("frontend").project;
const model = @import("../model.zig");
const Collector = @import("../collect.zig");
const rule = @import("generated_rx_publish_source_graph_edge");
const Input = std.meta.Child(rule.Input);
const Source = std.meta.Child(@typeInfo(@FieldType(Input, "source")).optional.child);
const Scope = std.meta.Child(@typeInfo(@FieldType(Source, "scope")).optional.child);
const Location = rx.ast.Location;

const Publication = struct {
    collector: *Collector,
    location: Location,
    role: model.Reference,
    named: bool = false,
    store_owner: ?[]const u8 = null,
    external: model.Target = undefined,
    fn borrow(handle: *const anyopaque) *const Publication {
        return @ptrCast(@alignCast(handle));
    }
    fn publish(self: *const Publication, selection: ?*const Source, compiled: bool) Collector.Error!void {
        const input: Input = .{ .target = @ptrCast(self), .source = selection, .compiled = compiled };
        var empty = std.heap.FixedBufferAllocator.init(&.{});

        zx.columns.invoke(rule.executeValue, empty.allocator(), &input) catch |err| switch (@as(anyerror, err)) {
            error.IndexOutOfBounds => unreachable,
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidGraph => return error.InvalidGraph,
            else => unreachable,
        };
    }
};

pub fn source(collector: *Collector, location: Location, role: model.Reference, selection: project.SourceSelection, details: struct {
    named: bool = false,
    store_owner: ?[]const u8 = null,
    boundary: ?project.ImportScope = null,
}) Collector.Error!void {
    const publication: Publication = .{
        .collector = collector,
        .location = location,
        .role = role,
        .named = details.named,
        .store_owner = details.store_owner,
    };

    const roots = zx.memory.borrowTextColumn("root", if (details.boundary) |scope| scope.scopes else &.{});

    const boundary: Scope = .{
        .roots = &.{ .items = @ptrCast(&roots), .length = roots.count },
        .owner = if (details.boundary) |scope| scope.owner else null,
        .windows = builtin.os.tag == .windows,
    };

    try publication.publish(&.{
        .path = selection.path,
        .index = &.{
            .keys = collector.paths.keys,
            .buckets = @ptrCast(&collector.paths.buckets),
            .capacity = collector.paths.buckets.len,
        },
        .matched = if (collector.options.source_index == collector.paths) selection.row else null,
        .scope = if (details.boundary != null and roots.count != 0) &boundary else null,
        .store_start = if (details.store_owner != null) collector.sources.rx_end else null,
    }, false);
}

pub fn external(collector: *Collector, location: Location, role: model.Reference, target: model.Target) Collector.Error!void {
    const publication: Publication = .{
        .collector = collector,
        .location = location,
        .role = role,
        .external = target,
    };

    try publication.publish(null, target == .compiled);
}

pub fn linkSourceGraphEdge(handle: *const anyopaque, row: u64) std.mem.Allocator.Error!void {
    const self = Publication.borrow(handle).collector;

    try self.targets.append(self.target_allocator, row);
}

pub fn appendSourceGraphEdge(handle: *const anyopaque, row: ?u64) std.mem.Allocator.Error!void {
    const self = Publication.borrow(handle);
    const target: model.Target = if (row) |value| .{ .source = @intCast(value) } else self.external;

    try self.collector.edges.append(self.collector.allocator, .{
        .target = target,
        .location = self.location,
        .reference = self.role,
        .named = self.named,
    });
}

pub fn markSourceGraphCompiled(handle: *const anyopaque) void {
    const self = Publication.borrow(handle).collector;

    self.modules.items(.compiled_dependency)[self.owner] = true;
}

pub fn rejectSourceGraphEdge(handle: *const anyopaque, store: bool, message: []const u8) Collector.Error!void {
    const self = Publication.borrow(handle);
    const collector = self.collector;

    if (!store) return collector.fail(self.location, message);

    collector.issue = .{
        .path = try collector.allocator.dupe(u8, self.store_owner.?),
        .location = self.location,
        .code = "capability",
        .message = message,
    };

    return error.InvalidGraph;
}
