const std = @import("std");
const zx = @import("zx");
const Nodes = @import("../nodes.zig");
const Initializer = @import("../../compiled.zig").StoreInitializer;
const Error = @import("../model.zig").Error;

pub fn remap(nodes: *Nodes, source: Initializer, own_identity: bool) Error!Initializer {
    if (comptime !@import("parser_options").generated_parser) {
        const identity = if (own_identity) try nodes.allocator.dupe(u8, source.identity) else source.identity;

        return .{ .identity = identity, .schema_version = source.schema_version, .function = try nodes.functionId(source.function) };
    }

    const rule = @import("generated_source_link_initializer");
    const Input = std.meta.Child(rule.Input);
    const Mapping = std.meta.Child(@FieldType(Input, "functions"));
    const functions = @import("remap.zig").idMapping(Mapping, nodes.functions);

    const input: Input = .{
        .source = &.{ .identity = source.identity, .schema_version = source.schema_version, .function = @backingInt(source.function) },
        .functions = &functions,
        .own_identity = own_identity,
    };

    const result = zx.columns.invoke(rule.executeValue, nodes.allocator, &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidModule,
    };

    return .{ .identity = result.identity, .schema_version = result.schema_version, .function = @fromBackingInt(result.function) };
}
