const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;

pub fn marshal(comptime Table: type, allocator: std.mem.Allocator, constants: []const ir.Constant) std.mem.Allocator.Error!?*const Table {
    if (constants.len == 0) return null;

    const Literal = std.meta.Child(std.meta.Child(@FieldType(Table, "values")));
    const names = try allocator.alloc([]const u8, constants.len);

    errdefer allocator.free(names);

    const values = try allocator.alloc(*const Literal, constants.len);

    errdefer allocator.free(values);

    const literals = try allocator.alloc(Literal, constants.len);

    errdefer allocator.free(literals);

    for (constants, names, values, literals) |constant, *name, *slot, *literal| {
        name.* = constant.name;
        literal.* = borrow(Literal, constant);
        slot.* = literal;
    }

    const table = try allocator.create(Table);

    table.* = .{ .names = names, .values = values };

    return table;
}

pub const borrow = ir.Constant.borrow;

pub fn nativeValid(types: ir.TypeTable, constants: []const ir.Constant) bool {
    const program = ir.Program{ .file_name = "", .types = types, .symbols = .{}, .expressions = .{}, .input_type = @fromBackingInt(0), .output_type = @fromBackingInt(0), .body = .{} };

    for (constants, 0..) |constant, index| {
        if (constant.name.len == 0) return false;

        for (constants[0..index]) |previous| {
            if (std.mem.eql(u8, constant.name, previous.name)) return false;
        }

        const expression = ir.ExpressionRow{ .type_id = constant.type_id, .span = .{ .start = 0, .end = 0 }, .value = value(@FieldType(ir.ExpressionRow, "value"), constant.value) };

        if (!@import("../../ir/seed_expression_rules.zig").validate(program, expression, 0)) return false;
    }

    return true;
}

pub fn value(comptime T: type, literal: ir.ConstantValue) T {
    return switch (literal) {
        .enumeration => |index| @unionInit(T, "enum_value", index),
        inline else => |payload, tag| @unionInit(T, @tagName(tag), payload),
    };
}

pub fn own(allocator: std.mem.Allocator, literal: anytype) std.mem.Allocator.Error!ir.ConstantValue {
    var result = view(literal);

    if (result == .string) result.string = try allocator.dupe(u8, result.string);

    return result;
}

pub fn view(literal: anytype) ir.ConstantValue {
    return switch (literal.kind) {
        .Integer => if (literal.negative) .{ .negative_integer = literal.integer } else .{ .integer = literal.integer },
        .Float => .{ .float = literal.floating },
        .String => .{ .string = literal.text },
        .Boolean => .{ .boolean = literal.boolean },
        .EnumValue => .{ .enumeration = literal.enumeration },
        else => unreachable,
    };
}
