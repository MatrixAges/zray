const std = @import("std");
const zx = @import("zx");
const Declaration = struct { symbol: []const u8, declaration: []const u8, domain: ?[]const u8 };

pub fn name(allocator: std.mem.Allocator, index: usize, output: bool) std.mem.Allocator.Error![]const u8 {
    const rule = @import("generated_verification_port_name");
    const input: std.meta.Child(rule.Input) = .{ .index = index, .output = output };

    return zx.columns.invoke(rule.executeValue, allocator, &input);
}

pub fn parameter(allocator: std.mem.Allocator, index: usize, width: u16, members: usize) std.mem.Allocator.Error!Declaration {
    const result = try @import("generated_verification_parameter").executeValue(allocator, &.{ .index = index, .width = width, .members = members });

    return .{ .symbol = result.symbol, .declaration = result.declaration, .domain = result.domain };
}

pub fn fieldPath(allocator: std.mem.Allocator, parent: []const u8, field: ?[]const u8, index: usize) std.mem.Allocator.Error![]const u8 {
    return @import("generated_verification_field_path").executeValue(allocator, &.{ .parent = parent, .field = field, .index = index });
}
