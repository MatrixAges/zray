const std = @import("std");
const dsl = @import("dsl");
const modules = @import("modules.zig");

pub fn validate(allocator: std.mem.Allocator, backing: std.mem.Allocator, registry: *const modules.Registry, sources: []const modules.Source, entries: []const []const u8, source_index: *usize, reporter: *dsl.Reporter) dsl.Error![]const usize {
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

    const result = execute(temporary, if (@typeInfo(Parameter) == .pointer) &input else input) catch |err| switch (err) {
        error.OutOfMemory, error.Overflow => return error.OutOfMemory,
        error.IndexOutOfBounds => unreachable,
    };

    if (result.message) |message| {
        const link = prepared.links[@intCast(result.edge)];

        source_index.* = @intCast(result.owner);

        return reporter.fail(.{
            .code = .context,
            .location = link.attribute.value_location,
            .element = link.node.name,
            .attribute = link.attribute.name,
            .message = message,
        });
    }

    std.debug.assert(result.count == sources.len);

    if (comptime native_width) return @ptrCast(rows);

    const order = try allocator.alloc(usize, rows.len);

    for (order, rows) |*target, value| target.* = @intCast(value);

    return order;
}
