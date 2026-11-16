const std = @import("std");
const generated = @import("parser_options").generated_parser;
const file_kind = if (generated) @import("generated_input_file_kind") else void;
pub const Kind = if (generated) file_kind.Output else enum { Ignored, ZX, RX, Template };

pub fn kind(name: []const u8) Kind {
    if (comptime generated) {
        var empty = std.heap.FixedBufferAllocator.init(&.{});

        return file_kind.executeValue(empty.allocator(), name) catch unreachable;
    }

    if (std.mem.endsWith(u8, name, ".zx")) return .ZX;
    if (std.mem.endsWith(u8, name, ".rx")) return .RX;
    if (std.mem.endsWith(u8, name, ".tpl")) return .Template;

    return .Ignored;
}

pub fn qualify(allocator: std.mem.Allocator, prefix: []const u8, parent: []const u8, name: []const u8) std.mem.Allocator.Error![]const u8 {
    if (comptime generated) {
        return @import("generated_input_logical_path").executeValue(allocator, &.{
            .prefix = prefix,
            .parent = parent,
            .name = name,
        });
    }

    return std.mem.concat(allocator, u8, &.{ prefix, parent, if (parent.len == 0) "" else "/", name });
}

/// The first match in discovery order or in a stable bytewise path order.
pub fn interfaceRow(comptime field: []const u8, records: anytype, path: []const u8, sorted: bool) ?usize {
    if (comptime generated) {
        const paths = @import("zxc_standard").memory.borrowTextColumn(field, records);
        var empty = std.heap.FixedBufferAllocator.init(&.{});

        const row = @import("generated_input_interface").executeValue(empty.allocator(), &.{
            .path = path,
            .paths = @ptrCast(&paths),
            .count = records.len,
            .sorted = sorted,
        }) catch unreachable;

        return if (row) |index| @intCast(index) else null;
    }

    if (!sorted and kind(path) != .ZX) return null;

    for (records, 0..) |*record, row| {
        if (std.mem.eql(u8, @field(record, field), path)) return row;
    }

    return null;
}
