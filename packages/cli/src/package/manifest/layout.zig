const std = @import("std");
const rule = @import("cli_source").manifest_layout;
const c = @import("yaml.zig").c;
const Scanner = @import("manifest_yaml_scanner");
const Field = @import("lint").configuration.yaml.Field;

pub fn collect(allocator: std.mem.Allocator, source: []const u8) ![]const Field {
    _ = try std.unicode.Utf8View.init(source);

    var parser: c.yaml_parser_t = undefined;

    if (c.yaml_parser_initialize(&parser) == 0) return error.OutOfMemory;

    defer c.yaml_parser_delete(&parser);
    c.yaml_parser_set_input_string(&parser, source.ptr, source.len);

    var scanner: Scanner = .{ .parser = &parser };

    defer scanner.deinit();

    const positions = try rule.executeValue(allocator, &.{ .scanner = @ptrCast(&scanner), .source = source });
    const fields = try allocator.alloc(Field, positions.len);

    for (positions, fields) |position, *field| {
        field.* = .{
            .span = .{ .start = @intCast(position.byte_start), .end = @intCast(position.byte_end) },
            .preserve_trailing = position.preserve_trailing,
        };
    }

    return fields;
}
