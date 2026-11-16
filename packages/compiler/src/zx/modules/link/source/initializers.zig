const std = @import("std");
const Initializer = @import("../../compiled.zig").StoreInitializer;
const Nodes = @import("../../artifact/nodes.zig");
const Error = @import("../../artifact/model.zig").Error;
const generated = @import("parser_options").generated_parser;

pub fn link(nodes: *Nodes, values: []const Initializer, shared: []const Initializer) Error![]const Initializer {
    if (values.len == 0) return &.{};

    const borrowed = if (nodes.functions == .range) reuse(values, shared, nodes.functions.range.prefix) else 0;

    if (borrowed == values.len) return shared[0..borrowed];

    const initializers = try nodes.allocator.alloc(Initializer, values.len);

    @memcpy(initializers[0..borrowed], shared[0..borrowed]);

    for (values[borrowed..], initializers[borrowed..]) |source, *initializer| initializer.* = try nodes.remapInitializer(source, true);

    return initializers;
}

fn reuse(values: []const Initializer, shared: []const Initializer, prefix: u32) usize {
    const count = @min(values.len, shared.len);

    if (count == 0) return 0;

    const same_rows = values.ptr == shared.ptr;

    if (comptime generated) {
        const memory = @import("zxc_standard").memory;
        const rule = @import("generated_source_initializer_prefix");
        const left = memory.borrowTextColumn("identity", values);
        const right = memory.borrowTextColumn("identity", shared);

        const input: std.meta.Child(rule.Input) = .{
            .left = &.{ .names = @ptrCast(&left), .data = left.bytes, .count = values.len },
            .right = &.{ .names = @ptrCast(&right), .data = right.bytes, .count = shared.len },
            .stride = @sizeOf(Initializer),
            .function_id = @offsetOf(Initializer, "function"),
            .schema_version = @offsetOf(Initializer, "schema_version"),
            .little_endian = @import("builtin").target.cpu.arch.endian() == .little,
            .shared = same_rows,
            .identity = true,
            .function_prefix = prefix,
        };

        var scratch = std.heap.FixedBufferAllocator.init(&.{});

        return @intCast(@import("zx").columns.invoke(rule.executeValue, scratch.allocator(), &input) catch unreachable);
    }

    for (values[0..count], shared[0..count], 0..) |source, owned, index| {
        if (@backingInt(source.function) >= prefix or (!same_rows and !std.meta.eql(source, owned))) return index;
    }

    return count;
}
