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

    const input: prepare.Input = .{
        .offsets = prepared.offsets,
        .targets = prepared.targets,
        .issues = prepared.issues,
    };

    const entry = if (selection) |request| requestedEntry(registry, sources, request.path) else null;

    if (entry) |root| {
        const result = @import("generated_graph_selection").executeValue(temporary, &.{
            .graph = &input,
            .selection = &.{ .root = root },
        }) catch |err| switch (err) {
            error.OutOfMemory, error.Overflow => return error.OutOfMemory,
            error.IndexOutOfBounds => unreachable,
        };

        if (result.message) |message| return fail(temporary, &prepared, sources, source_index, reporter, result.owner, result.edge, message);

        std.debug.assert(result.count == sources.len and result.order.len == sources.len);

        const marks = try allocator.dupe(u32, result.marks);

        errdefer allocator.free(marks);

        const order = try copyOrder(allocator, result.order, native_width);

        selection.?.marks = marks;

        return order;
    }

    const result = execute(temporary, if (@typeInfo(Parameter) == .pointer) &input else input) catch |err| switch (err) {
        error.OutOfMemory, error.Overflow => return error.OutOfMemory,
        error.IndexOutOfBounds => unreachable,
    };

    if (result.message) |message| return fail(temporary, &prepared, sources, source_index, reporter, result.owner, result.edge, message);

    std.debug.assert(result.count == sources.len and result.order.len == sources.len);

    return copyOrder(allocator, result.order, native_width);
}

fn copyOrder(allocator: std.mem.Allocator, rows: []const u64, comptime native_width: bool) std.mem.Allocator.Error![]const usize {
    if (comptime native_width) return allocator.dupe(usize, @ptrCast(rows));

    const order = try allocator.alloc(usize, rows.len);

    for (order, rows) |*target, value| target.* = @intCast(value);

    return order;
}

fn fail(temporary: std.mem.Allocator, prepared: anytype, sources: []const modules.Source, source_index: *usize, reporter: *dsl.Reporter, owner: u64, edge: u64, message: []const u8) dsl.Error![]const usize {
    const prepare = @import("dependency_graph/prepare.zig");
    const owner_index: usize = @intCast(owner);
    const row = prepared.references[@intCast(edge)];
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

fn requestedEntry(registry: *const modules.Registry, sources: []const modules.Source, path: []const u8) ?usize {
    const entry = registry.get(path) orelse return null;

    return if (std.mem.eql(u8, sources[entry].path, path)) entry else null;
}
