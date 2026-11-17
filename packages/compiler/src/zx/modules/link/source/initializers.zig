const std = @import("std");
const zx = @import("zx");
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

    if (comptime generated) {
        try publish(nodes, values, initializers, borrowed);
    } else {
        for (values[borrowed..], initializers[borrowed..]) |source, *initializer| initializer.* = try nodes.remapInitializer(source, true);
    }

    return initializers;
}

fn publish(nodes: *const Nodes, values: []const Initializer, initializers: []Initializer, start: usize) Error!void {
    const rule = @import("generated_source_initializer_publish");
    const Input = std.meta.Child(rule.Input);
    const Mapping = std.meta.Child(@FieldType(Input, "functions"));
    const memory = zx.memory;
    const functions = @import("../../artifact/nodes/remap.zig").idMapping(Mapping, nodes.functions);
    const identities = memory.borrowTextColumn("identity", values);
    const ids = memory.borrowReadColumn(zx.ir.FunctionId, "function", values);
    const schemas = memory.borrowReadColumn(u32, "schema_version", values);
    const out_identities = memory.borrowWriteColumn([]const u8, "identity", initializers);
    const out_ids = memory.borrowWriteColumn(u32, "function", initializers);
    const out_schemas = memory.borrowWriteColumn(u32, "schema_version", initializers);

    const input: Input = .{
        .source = &.{ .identity = @ptrCast(&identities), .function = @ptrCast(&ids), .schema_version = @ptrCast(&schemas) },
        .target = &.{ .identity = @ptrCast(&out_identities), .function = @ptrCast(&out_ids), .schema_version = @ptrCast(&out_schemas) },
        .functions = &functions,
        .start = start,
        .end = values.len,
    };

    zx.columns.invoke(rule.executeValue, nodes.allocator, &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidModule,
    };
}

fn reuse(values: []const Initializer, shared: []const Initializer, prefix: u32) usize {
    const count = @min(values.len, shared.len);

    if (count == 0) return 0;

    const same_rows = values.ptr == shared.ptr;

    if (comptime generated) {
        const memory = @import("zx").memory;
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
