const std = @import("std");
const ast = @import("dsl").ast;
const zx = @import("zx");
const rows = @import("../attribute/rows.zig");
const binding = @import("generated_rx_bind_attributes");
const BindOutput = @typeInfo(@TypeOf(binding.executeValue(undefined, undefined))).error_union.payload;
pub const supports = rows.supports;

pub fn bind(node: anytype, fields: []const []const u8, required: []const u64, slots: []u64) struct { issue: @FieldType(BindOutput, "issue"), row: usize } {
    if (node.attributeCount() == 0 and required.len == 0) return .{ .issue = .None, .row = 0 };

    const Input = std.meta.Child(binding.Input);
    const Columns = std.meta.Child(@FieldType(Input, "rows"));
    const borrowed = rows.bind(node);
    const view = borrowed.wire(Columns, node);
    const finding = execute(binding, &.{ .rows = &view, .fields = fields, .required = required, .slots = @ptrCast(&slots) });

    return .{ .issue = finding.issue, .row = @intCast(finding.row) };
}

pub fn select(name: []const u8, names: []const []const u8) ?usize {
    const row = execute(@import("generated_rx_schema_position"), &.{ .name = name, .names = names }) orelse return null;

    return @intCast(row);
}

pub fn childCount(count: usize, min: usize, max: usize) ?usize {
    const row = execute(@import("generated_rx_schema_child_count"), &.{ .count = count, .min = min, .max = max }) orelse return null;

    return @intCast(row);
}

pub fn unexpectedText(node: anytype) ?ast.Location {
    if (comptime @TypeOf(node) != ast.View) return node.unexpectedText();

    const text = node.node.text;

    if (text.len == 0) return null;

    const values = zx.memory.borrowTextColumn("value", text);
    const row = execute(@import("generated_rx_schema_native_text"), &.{ .text = @ptrCast(&values), .count = text.len }) orelse return null;

    return text[@intCast(row)].location;
}

fn execute(comptime Rule: type, input: *const std.meta.Child(Rule.Input)) @typeInfo(@TypeOf(Rule.executeValue(undefined, undefined))).error_union.payload {
    var empty = std.heap.FixedBufferAllocator.init(&.{});

    return zx.columns.invoke(Rule.executeValue, empty.allocator(), input) catch unreachable;
}
