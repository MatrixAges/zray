const std = @import("std");
const dsl = @import("dsl");
const modules = @import("modules.zig");

pub const Selection = struct { path: []const u8, marks: ?[]const u32 = null };

pub fn validate(allocator: std.mem.Allocator, backing: std.mem.Allocator, registry: *const modules.Registry, sources: []const modules.Source, entries: []const []const u8, selection: ?*Selection, source_index: *usize, reporter: *dsl.Reporter) dsl.Error![]const usize {
    if (!@import("rx_options").generated_graph) return @import("dependency_graph/seed.zig").validate(allocator, sources, entries, source_index, reporter);

    var arena = std.heap.ArenaAllocator.init(backing);

    defer arena.deinit();

    const temporary = arena.allocator();
    const prepare = @import("dependency_graph/prepare.zig");
    const prepared = try prepare.build(temporary, registry, sources, entries);
    const execute = @import("generated_graph").executeValue;
    const Parameter = @typeInfo(@TypeOf(execute)).@"fn".param_types[1].?;
    const native_width = @sizeOf(usize) == @sizeOf(u64) and @alignOf(u64) >= @alignOf(usize);
    const owner = if (native_width) allocator else temporary;
    const rows = try owner.alloc(u64, sources.len);

    errdefer owner.free(rows);

    const input: prepare.Input = .{
        .offsets = prepared.offsets,
        .targets = prepared.targets,
        .issues = prepared.issues,
        .order = @ptrCast(&rows),
        .capacity = rows.len,
    };

    const entry = if (selection) |request| requestedEntry(registry, sources, request.path) else null;
    const marks = if (entry != null) try allocator.alloc(u32, sources.len) else null;

    if (marks) |membership| @memset(membership, 0);

    const result = (if (entry) |root|
        @import("generated_graph_selection").executeValue(temporary, &.{
            .graph = &input,
            .selection = &.{ .root = root, .marks = @ptrCast(&marks.?) },
        })
    else
        execute(temporary, if (@typeInfo(Parameter) == .pointer) &input else input)) catch |err| switch (err) {
        error.OutOfMemory, error.Overflow => return error.OutOfMemory,
        error.IndexOutOfBounds => unreachable,
    };

    if (result.message) |message| {
        const owner_index: usize = @intCast(result.owner);
        const row = prepared.references[@intCast(result.edge)];
        const link = try prepare.link(temporary, &sources[owner_index], row);

        source_index.* = owner_index;

        return reporter.fail(.{
            .code = .context,
            .location = link.attribute.value_location,
            .element = link.node.name,
            .attribute = link.attribute.name,
            .message = message,
        });
    }

    std.debug.assert(result.count == sources.len);

    if (selection) |request| request.marks = marks;
    if (comptime native_width) return @ptrCast(rows);

    const order = try allocator.alloc(usize, rows.len);

    for (order, rows) |*target, value| target.* = @intCast(value);

    return order;
}

fn requestedEntry(registry: *const modules.Registry, sources: []const modules.Source, path: []const u8) ?usize {
    const entry = registry.get(path) orelse return null;

    return if (std.mem.eql(u8, sources[entry].path, path)) entry else null;
}
