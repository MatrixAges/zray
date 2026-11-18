const std = @import("std");
const dsl = @import("dsl");

pub fn fail(input: anytype, key: []const u8, message: []const u8, reporter: *dsl.Reporter) dsl.Error {
    const node = dsl.ast.view(input);

    for (0..node.attributeCount()) |index| {
        const item = node.schemaAttribute(index);

        if (std.mem.eql(u8, item.name, key)) return reporter.fail(.{
            .code = .context,
            .location = item.value_location,
            .element = node.name(),
            .attribute = key,
            .message = message,
        });
    }

    return reporter.fail(.{
        .code = .context,
        .location = node.location(),
        .element = node.name(),
        .attribute = key,
        .message = message,
    });
}

pub fn attribute(input: anytype, name: []const u8) ?[]const u8 {
    return if (find(input, name)) |item| item.value else null;
}

pub fn uniqueChildren(input: anytype, tag: []const u8, key: []const u8, reporter: *dsl.Reporter) dsl.Error!void {
    const node = dsl.ast.view(input);
    var children = node.children();
    var index: usize = 0;

    while (children.next()) |item| : (index += 1) {
        const child = dsl.ast.view(item);

        if (!std.mem.eql(u8, child.name(), tag)) continue;

        const current = find(child, key).?;
        var earlier = node.children();

        for (0..index) |_| {
            const previous = dsl.ast.view(earlier.next().?);

            if (!std.mem.eql(u8, previous.name(), tag)) continue;

            const prior = find(previous, key).?;

            if (current.kind == prior.kind and std.mem.eql(u8, current.value, prior.value)) {
                return fail(child, key, "Duplicate RX declaration", reporter);
            }
        }
    }
}

fn find(input: anytype, name: []const u8) ?dsl.ast.Attribute {
    const node = dsl.ast.view(input);

    for (0..node.attributeCount()) |index| {
        const item = node.schemaAttribute(index);

        if (std.mem.eql(u8, item.name, name)) return item;
    }

    return null;
}

pub const validate = @import("schema/attribute/adapter.zig").check;

pub fn attributeSchema(comptime Schema: type, comptime policy: @import("schema/attribute/adapter.zig").Policy) type {
    return dsl.refine(Schema, struct {
        fn check(data: Schema.Data, node: anytype, _: anytype, reporter: *dsl.Reporter) dsl.Error!void {
            try validate(policy, data.attributes, node, reporter);
        }
    }.check);
}
