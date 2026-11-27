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
    fn publish(
        collector: *Collector,
        location: Location,
        role: model.Reference,
        store_owner: ?[]const u8,
        external_target: model.Target,
        selection: ?*const Source,
        compiled: bool,
    ) Collector.Error!void {
        const temporary = collector.temporary.allocator();

        const input: Input = .{
            .source = selection,
            .compiled = compiled,
            .release = @ptrCast(&temporary),
        };

        const result = zx.columns.invoke(rule.executeValue, temporary, &input) catch |err| switch (@as(anyerror, err)) {
            error.OutOfMemory, error.Overflow, error.WriteFailed => return error.OutOfMemory,
            else => unreachable,
        };

        if (!result.ok) {
            const message = result.message.?;

            if (!result.store_error) return collector.fail(location, message);

            collector.issue = .{
                .path = try collector.allocator.dupe(u8, store_owner.?),
                .location = location,
                .code = "capability",
                .message = message,
            };

            return error.InvalidGraph;
        }

        if (result.compiled) {
            collector.modules.items(.compiled_dependency)[collector.owner] = true;
        }

        const target: model.Target = if (result.target) |value| blk: {
            const index: usize = @intCast(value);

            try collector.targets.append(collector.target_allocator, index);

            break :blk .{ .source = index };
        } else external_target;

        try collector.edges.append(collector.allocator, .{
            .target = target,
            .location = location,
            .reference = role,
            .named = result.named,
        });
    }
};

pub fn source(collector: *Collector, location: Location, role: model.Reference, selection: project.SourceSelection, details: struct {
    store_owner: ?[]const u8 = null,
    relative: bool = false,
    member_width: ?usize = null,
    boundary: ?project.ImportScope = null,
}) Collector.Error!void {
    const roots = zx.memory.borrowTextColumn("root", if (details.boundary) |scope| scope.scopes else &.{});

    const boundary: Scope = .{
        .roots = &.{ .items = @ptrCast(&roots), .length = roots.count },
        .owner = if (details.boundary) |scope| scope.owner else null,
        .windows = builtin.os.tag == .windows,
    };

    const other = collector.options.source_index;
    const index = table(collector.paths);
    const alternate = if (other != collector.paths) table(other.?) else undefined;

    try Publication.publish(collector, location, role, details.store_owner, undefined, &.{
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
    try Publication.publish(collector, location, role, null, target, null, target == .compiled);
}
