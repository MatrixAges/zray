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
const Table = std.meta.Child(@FieldType(Source, "index"));
const Scope = std.meta.Child(@typeInfo(@FieldType(Source, "scope")).optional.child);
const Location = rx.ast.Location;

const Publication = struct {
    collector: *Collector,
    location: Location,
    role: model.Reference,
    store_owner: ?[]const u8 = null,
    external: model.Target = undefined,
    fn borrow(handle: *const anyopaque) *const Publication {
        return @ptrCast(@alignCast(handle));
    }
    fn publish(self: *const Publication, selection: ?*const Source, compiled: bool) Collector.Error!void {
        const collector = self.collector;
        const temporary = collector.temporary.allocator();
        var flag: []bool = collector.modules.items(.compiled_dependency)[collector.owner..][0..1];

        const input: Input = .{
            .target = @ptrCast(self),
            .source = selection,
            .resources = &.{
                .allocator = @ptrCast(&collector.target_allocator),
                .targets = @ptrCast(&collector.targets),
                .compiled = if (compiled) @ptrCast(&flag) else null,
            },
            .release = @ptrCast(&temporary),
        };

        zx.columns.invoke(rule.executeValue, temporary, &input) catch |err| switch (@as(anyerror, err)) {
            error.OutOfMemory, error.Overflow, error.WriteFailed => return error.OutOfMemory,
            error.InvalidGraph => return error.InvalidGraph,
            else => unreachable,
        };
    }
};

pub fn source(collector: *Collector, location: Location, role: model.Reference, selection: project.SourceSelection, details: struct {
    store_owner: ?[]const u8 = null,
    relative: bool = false,
    member_width: ?usize = null,
    boundary: ?project.ImportScope = null,
}) Collector.Error!void {
    const publication: Publication = .{
        .collector = collector,
        .location = location,
        .role = role,
        .store_owner = details.store_owner,
    };

    const roots = zx.memory.borrowTextColumn("root", if (details.boundary) |scope| scope.scopes else &.{});

    const boundary: Scope = .{
        .roots = &.{ .items = @ptrCast(&roots), .length = roots.count },
        .owner = if (details.boundary) |scope| scope.owner else null,
        .windows = builtin.os.tag == .windows,
    };

    const other = collector.options.source_index;
    const index = table(collector.paths);
    const alternate = if (other != collector.paths) table(other.?) else undefined;

    try publication.publish(&.{
        .path = selection.path,
        .index = &index,
        .matched = if (other == collector.paths) selection.row else null,
        .scope = if (details.boundary != null and roots.count != 0) &boundary else null,
        .store_start = if (details.store_owner != null) collector.sources.rx_end else null,
        .root = if (details.relative) collector.options.root_dir else null,
        .member_width = details.member_width,
        .selection_index = if (other != collector.paths) &alternate else null,
    }, false);
}

fn table(index: *const project.source_index.Map) Table {
    return .{ .keys = index.keys, .buckets = @ptrCast(&index.buckets), .capacity = index.buckets.len };
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

pub fn appendSourceGraphEdge(handle: *const anyopaque, row: ?u64, named: bool) std.mem.Allocator.Error!void {
    const self = Publication.borrow(handle);
    const target: model.Target = if (row) |value| .{ .source = @intCast(value) } else self.external;

    try self.collector.edges.append(self.collector.allocator, .{
        .target = target,
        .location = self.location,
        .reference = self.role,
        .named = named,
    });
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
