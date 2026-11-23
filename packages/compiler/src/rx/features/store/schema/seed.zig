const std = @import("std");
const dsl = @import("dsl");
const checks = @import("../../../checks.zig");
const Groups = @import("adapter.zig").Groups;

pub fn check(children: anytype, node: anytype, reporter: *dsl.Reporter) dsl.Error!void {
    try checks.uniqueChildren(node, "Type", "as", reporter);

    var has_objects = false;

    for (children, 0..) |child, index| {
        if (child == .type) {
            if (has_objects) return checks.fail(dsl.ast.childAt(node, index), "from", "Type declarations must precede Store objects", reporter);
        } else has_objects = true;
    }

    if (!has_objects) return checks.fail(node, "", "Store requires at least one Object", reporter);

    for (children, 0..) |child, index| {
        if (child != .object) continue;

        for (children[0..index]) |previous| {
            if (previous != .object) continue;
            if (!std.mem.eql(u8, child.object.attributes.name, previous.object.attributes.name)) continue;

            for (child.object.children, 0..) |field, row| {
                for (previous.object.children) |prior| {
                    if (std.mem.eql(u8, field.attributes.name, prior.attributes.name)) {
                        const object = dsl.ast.childAt(node, index);

                        return checks.fail(dsl.ast.childAt(object, row), "name", "Store object field path is already declared", reporter);
                    }
                }
            }
        }
    }
}

pub fn group(allocator: std.mem.Allocator, input: anytype) std.mem.Allocator.Error!Groups {
    const node = dsl.ast.view(input);
    var children = node.children();
    var first: usize = 0;
    var current = children.next();

    while (current) |item| : (first += 1) {
        if (!std.mem.eql(u8, dsl.ast.view(item).name(), "Type")) break;

        current = children.next();
    }

    const count = node.childCount() - first;

    if (count > std.math.maxInt(u32)) return error.OutOfMemory;
    if (count == 1) return .singleton(first);

    var tails: std.StringHashMapUnmanaged(u32) = .empty;

    defer tails.deinit(allocator);

    const starts = try allocator.alloc(u32, count);
    const next = try allocator.alloc(?u32, count);
    const offsets = try allocator.alloc(u64, count + 1);

    @memset(next, null);

    var groups: usize = 0;
    var fields: usize = 0;

    for (0..count) |index| {
        const fragment = dsl.ast.view(current.?);
        const name = checks.attribute(fragment, "name").?;
        const entry = try tails.getOrPut(allocator, name);

        if (entry.found_existing) {
            next[entry.value_ptr.*] = @intCast(index);
        } else {
            starts[groups] = @intCast(index);
            groups += 1;
        }

        entry.value_ptr.* = @intCast(index);
        offsets[index] = fields;
        fields = std.math.add(usize, fields, fragment.childCount()) catch return error.OutOfMemory;
        current = children.next();
    }

    offsets[count] = fields;

    return .{ .first = first, .starts = starts[0..groups], .next = next, .offsets = offsets };
}
