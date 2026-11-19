const std = @import("std");
const generated = @import("parser_options").generated_parser;
const file_kind = if (generated) @import("generated_input_file_kind") else void;
pub const Kind = if (generated) file_kind.Output else enum { Ignored, ZX, RX, Template };
pub const interfaces = @import("collection/interface.zig");
pub const catalog = @import("collection/catalog.zig");
pub const order = @import("collection/order.zig");

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
