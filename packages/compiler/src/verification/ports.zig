const std = @import("std");
const zx = @import("zx");
const generated = @import("parser_options").generated_parser;
const Declaration = struct { symbol: []const u8, declaration: []const u8, domain: ?[]const u8 };

pub fn name(allocator: std.mem.Allocator, index: usize, output: bool) std.mem.Allocator.Error![]const u8 {
    if (comptime generated) {
        const rule = @import("generated_verification_port_name");
        const input: std.meta.Child(rule.Input) = .{ .index = index, .output = output };

        return zx.columns.invoke(rule.executeValue, allocator, &input);
    }

    return std.fmt.allocPrint(allocator, "{s}_{d}", .{ if (output) "output" else "input", index });
}

pub fn parameter(allocator: std.mem.Allocator, index: usize, width: u16, members: usize) std.mem.Allocator.Error!Declaration {
    if (comptime generated) {
        const result = try @import("generated_verification_parameter").executeValue(allocator, &.{ .index = index, .width = width, .members = members });

        return .{ .symbol = result.symbol, .declaration = result.declaration, .domain = result.domain };
    }

    const symbol = try name(allocator, index, false);
    const sort = if (width == 0) "Bool" else try std.fmt.allocPrint(allocator, "(_ BitVec {d})", .{width});

    return .{
        .symbol = symbol,
        .declaration = try std.fmt.allocPrint(allocator, "(declare-fun {s} () {s})", .{ symbol, sort }),
        .domain = if (members == 0) null else try std.fmt.allocPrint(allocator, "(assert (bvule {s} (_ bv{d} {d})))", .{ symbol, members - 1, width }),
    };
}

pub fn fieldPath(allocator: std.mem.Allocator, parent: []const u8, field: ?[]const u8, index: usize) std.mem.Allocator.Error![]const u8 {
    if (comptime generated) {
        return @import("generated_verification_field_path").executeValue(allocator, &.{ .parent = parent, .field = field, .index = index });
    }

    if (field) |label| return std.fmt.allocPrint(allocator, "{s}.{s}", .{ parent, label });

    return std.fmt.allocPrint(allocator, "{s}[{d}]", .{ parent, index });
}
