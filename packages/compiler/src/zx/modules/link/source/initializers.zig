const std = @import("std");
const Initializer = @import("../../compiled.zig").StoreInitializer;
const Nodes = @import("../../artifact/nodes.zig");
const Error = @import("../../artifact/model.zig").Error;

pub fn link(nodes: *Nodes, values: []const Initializer, shared: []const Initializer) Error![]const Initializer {
    if (values.len == 0) return &.{};

    const borrowed = if (nodes.functions == .range) reuse(values, shared, nodes.functions.range.prefix) else 0;

    if (borrowed == values.len) return shared[0..borrowed];

    const initializers = try nodes.allocator.alloc(Initializer, values.len);

    @memcpy(initializers[0..borrowed], shared[0..borrowed]);

    for (values[borrowed..], initializers[borrowed..]) |source, *initializer| {
        initializer.* = .{
            .identity = try nodes.allocator.dupe(u8, source.identity),
            .schema_version = source.schema_version,
            .function = try nodes.functionId(source.function),
        };
    }

    return initializers;
}

fn reuse(values: []const Initializer, shared: []const Initializer, prefix: u32) usize {
    const count = @min(values.len, shared.len);

    for (values[0..count], shared[0..count], 0..) |source, owned, index| {
        if (@backingInt(source.function) >= prefix or !std.meta.eql(source, owned)) return index;
    }

    return count;
}
