const std = @import("std");
const dsl = @import("dsl");
const modules = @import("../../modules.zig");
const schema = @import("../../flow.zig").Module;

pub fn run(allocator: std.mem.Allocator, schemas: std.mem.Allocator, data: ?[]modules.Module, sources: []const modules.Source, registry: *modules.Registry, source_index: *usize, reporter: *dsl.Reporter) dsl.Error!void {
    const rule = @import("generated_rx_register_graph_modules");
    const zx = @import("zx");
    const paths = zx.memory.borrowTextColumn("path", sources);

    const input: std.meta.Child(rule.Input) = .{
        .source = @ptrCast(&paths),
        .count = sources.len,
        .buckets = registry.buckets,
    };

    // The caller's result arena owns the normalized path bytes.
    const registered = zx.columns.invoke(rule.executeIn, allocator, &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.Overflow, error.IntegerOverflow => return error.OutOfMemory,
        else => unreachable,
    };

    for (registered.keys, 0..) |path, row| {
        const source = &sources[row];

        source_index.* = row;
        registry.keys[row] = path;

        if (data) |items| {
            items[row] = .{ .path = path, .data = try schema.decode(allocator, source.node, reporter, source.callSequence()) };
        } else if (!source.hasSchema()) {
            _ = try schema.decode(schemas, source.node, reporter, source.callSequence());
        }
    }

    if (registered.issue) |message| {
        const row = registered.keys.len;
        const node = sources[row].node;

        source_index.* = row;

        return reporter.fail(.{ .code = .context, .location = node.location, .element = node.name, .message = message });
    }

    if (registered.buckets.ptr != registry.buckets.ptr) @memcpy(registry.buckets, registered.buckets);
}
