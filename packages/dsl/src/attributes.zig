const std = @import("std");
const ast = @import("ast.zig");
const diagnostic = @import("diagnostic.zig");

pub fn checkType(comptime T: type) void {
    switch (@typeInfo(T)) {
        .bool, .int, .float, .@"enum" => {},
        .optional => |info| checkType(info.child),
        else => if (T != []const u8) @compileError("Unsupported DSL attribute type: " ++ @typeName(T)),
    }
}

const Binding = struct {
    issue: enum { None, Unknown, Duplicate, Missing } = .None,
    row: usize = 0,
};

pub fn decode(comptime Rules: type, comptime T: type, input: anytype, reporter: *diagnostic.Reporter) diagnostic.Error!T {
    const node = ast.view(input);
    const info = @typeInfo(T).@"struct";
    const required = comptime requiredFields(T);
    var slots: [info.field_names.len]u64 = @splat(0);

    const binding = if (comptime Rules != void and Rules.supports(@TypeOf(node)))
        Rules.bind(node, info.field_names, required, &slots)
    else
        bindSeed(node, info.field_names, required, &slots);

    if (binding.issue == .Unknown or binding.issue == .Duplicate) {
        const attribute = node.schemaAttribute(binding.row);
        const unknown = binding.issue == .Unknown;

        return reporter.fail(.{
            .code = if (unknown) .unknown_attribute else .duplicate_attribute,
            .location = attribute.location,
            .element = node.name(),
            .attribute = attribute.name,
            .message = if (unknown) "Attribute is not allowed on this element" else "Attribute occurs more than once",
        });
    }

    var result: T = undefined;

    inline for (info.field_names, info.field_types, info.field_attrs, slots, 0..) |field_name, field_type, field_attrs, index, ordinal| {
        if (index != 0) {
            const attribute = node.schemaAttribute(@intCast(index - 1));
            const source = if (attribute.kind == .expression) std.mem.trim(u8, attribute.value, " \t\r\n") else attribute.value;

            @field(result, field_name) = convert(field_type, source) catch return reporter.fail(.{
                .code = .invalid_attribute,
                .location = attribute.value_location,
                .element = node.name(),
                .attribute = attribute.name,
                .expected = @typeName(field_type),
                .message = "Attribute value does not match its declared type",
            });
        } else {
            if (field_attrs.defaultValue(field_type)) |value| {
                @field(result, field_name) = value;
            } else if (@typeInfo(field_type) == .optional) {
                @field(result, field_name) = null;
            } else {
                if (binding.issue == .Missing and binding.row == ordinal) return reporter.fail(.{
                    .code = .missing_attribute,
                    .location = node.location(),
                    .element = node.name(),
                    .attribute = field_name,
                    .expected = @typeName(field_type),
                    .message = "Required attribute is missing",
                });

                unreachable;
            }
        }
    }

    return result;
}

fn requiredFields(comptime T: type) []const u64 {
    const info = @typeInfo(T).@"struct";
    var result: []const u64 = &.{};

    for (info.field_types, info.field_attrs, 0..) |field_type, field_attrs, row| {
        if (@typeInfo(field_type) != .optional and field_attrs.defaultValue(field_type) == null) result = result ++ .{row};
    }

    return result;
}

fn bindSeed(node: anytype, names: []const []const u8, required: []const u64, slots: []u64) Binding {
    for (0..node.attributeCount()) |row| {
        const attribute = node.schemaAttribute(row);

        const slot = for (names, 0..) |name, ordinal| {
            if (std.mem.eql(u8, name, attribute.name)) break ordinal;
        } else return .{ .issue = .Unknown, .row = row };

        if (slots[slot] != 0) return .{ .issue = .Duplicate, .row = row };

        slots[slot] = row + 1;
    }

    for (required) |row| {
        if (slots[@intCast(row)] == 0) return .{ .issue = .Missing, .row = @intCast(row) };
    }

    return .{};
}

fn convert(comptime T: type, value: []const u8) error{InvalidValue}!T {
    if (T == []const u8) return value;

    return switch (@typeInfo(T)) {
        .optional => |info| try convert(info.child, value),
        .bool => if (std.mem.eql(u8, value, "true")) true else if (std.mem.eql(u8, value, "false")) false else error.InvalidValue,
        .int => std.fmt.parseInt(T, value, 10) catch error.InvalidValue,
        .float => blk: {
            const number = std.fmt.parseFloat(T, value) catch return error.InvalidValue;

            if (!std.math.isFinite(number)) return error.InvalidValue;

            break :blk number;
        },
        .@"enum" => std.meta.stringToEnum(T, value) orelse error.InvalidValue,
        else => unreachable,
    };
}
