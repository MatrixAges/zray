const std = @import("std");
const generated = @import("parser_options").generated_parser;
const file_kind = if (generated) @import("generated_input_file_kind") else void;
pub const Kind = if (generated) file_kind.Output else enum { Ignored, ZX, RX, Template };
pub const interface_seed = @import("collection/interface_seed.zig");
pub const catalog = @import("collection/catalog.zig");
pub const order = @import("collection/order.zig");
pub const directory = @import("collection/directory.zig");
pub const darwin_directory = @import("collection/darwin.zig");

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
        const rule = @import("generated_input_logical_path");
        const Input = if (@typeInfo(rule.Input) == .pointer) std.meta.Child(rule.Input) else rule.Input;

        const request: Input = .{
            .prefix = prefix,
            .parent = parent,
            .name = name,
        };

        return @import("zx").columns.invoke(rule.executeValue, allocator, &request);
    }

    return std.mem.concat(allocator, u8, &.{ prefix, parent, if (parent.len == 0) "" else "/", name });
}
