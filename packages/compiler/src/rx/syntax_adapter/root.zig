const std = @import("std");
const dsl = @import("dsl");
const zx = @import("zx");
const ast = dsl.ast;
pub const values = @import("value.zig");
pub const references = @import("references.zig");

const Document = struct { node: dsl.ast.Node, references: ?*const references.Index = null };

pub fn location(input: anytype) dsl.ast.Location {
    return .{ .offset = @intCast(input.offset), .line = @intCast(input.line), .column = @intCast(input.column) };
}

comptime {
    const Kind = @FieldType(ast.Attribute, "kind");

    std.debug.assert(@sizeOf(Kind) == 1 and @backingInt(Kind.string) == 0 and @backingInt(Kind.expression) == 1);
}

pub fn convert(comptime rules: anytype, allocator: std.mem.Allocator, temporary: std.mem.Allocator, source: []const u8, input: anytype) !Document {
    const tree = input.tree;
    const decoded = try values.materialize(rules.decode, allocator, source, tree.parts, input.control.decoded_length);
    const nodes = try allocator.alloc(ast.Node, tree.nodes.len);
    const attributes = try allocator.alloc(ast.Attribute, tree.attributes.len);
    const text = try allocator.alloc(ast.Text, tree.text.len);
    const Parameter = @typeInfo(@TypeOf(rules.publish)).@"fn".param_types[1].?;
    const Input = if (@typeInfo(Parameter) == .pointer) std.meta.Child(Parameter) else Parameter;
    const indexed = @TypeOf(rules.scan) != @TypeOf(null);

    const publication: Input = .{
        .source = source,
        .decoded = decoded,
        .tree = .{
            .attributes = tree.attributes,
            .nodes = tree.nodes,
            .parts = tree.parts,
            .text = tree.text,
        },
        .root = input.control.result,
        .indexed = indexed,
    };

    const published = (if (comptime @typeInfo(Parameter) == .pointer)
        rules.publish(temporary, &publication)
    else
        rules.publish(temporary, publication)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };

    for (published.attributes, 0..) |item, i| {
        attributes[i] = .{
            .kind = @fromBackingInt(@intCast(item.kind)),
            .name = item.name,
            .value = item.value,
            .raw_value = item.raw_value,
            .location = location(item.location),
            .value_location = location(item.value_location),
        };
    }

    for (published.text) |item| {
        text[@intCast(item.slot)] = .{
            .value = item.value,
            .location = location(item.location),
        };
    }

    for (published.nodes) |item| {
        const attr_start: usize = @intCast(item.attribute_start);
        const attr_count: usize = @intCast(item.attribute_count);
        const child_start: usize = @intCast(item.child_start);
        const child_count: usize = @intCast(item.child_count);
        const text_start: usize = @intCast(item.text_start);
        const text_count: usize = @intCast(item.text_count);

        nodes[@intCast(item.slot)] = .{
            .name = item.name,
            .location = location(item.location),
            .attributes = attributes[attr_start..][0..attr_count],
            .children = nodes[child_start..][0..child_count],
            .text = text[text_start..][0..text_count],
        };
    }

    return .{
        .node = nodes[0],
        .references = if (comptime indexed) try references.build(rules.scan, rules.references, allocator, temporary, source, input, published.node_slots, nodes, attributes, @intCast(published.extent)) else null,
    };
}
