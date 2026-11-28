const std = @import("std");
const rule = @import("cli_source").manifest_layout;
const Scanner = @import("manifest_yaml_scanner");
const Field = @import("lint").configuration.yaml.Field;

pub fn collect(allocator: std.mem.Allocator, source: []const u8) ![]const Field {
    _ = try std.unicode.Utf8View.init(source);

    var scratch = std.heap.ArenaAllocator.init(allocator);

    defer scratch.deinit();

    const temporary = scratch.allocator();
    const tokens = try Scanner.read(temporary, source);

    const positions = try rule.executeValue(temporary, &.{
        .tokens = &.{
            .kinds = tokens.kinds,
            .starts = tokens.starts,
            .ends = tokens.ends,
            .block_scalars = tokens.block_scalars,
        },
        .source = source,
    });

    const fields = try allocator.alloc(Field, positions.len);

    for (positions, fields) |position, *field| {
        field.* = .{
            .span = .{ .start = @intCast(position.byte_start), .end = @intCast(position.byte_end) },
            .preserve_trailing = position.preserve_trailing,
        };
    }

    return fields;
}
