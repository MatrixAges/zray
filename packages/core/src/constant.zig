const TypeId = @import("type_table/model.zig").TypeId;
pub const Value = @import("memory").Scalar;

pub const Constant = struct {
    name: []const u8,
    type_id: TypeId,
    value: Value,
    pub fn borrow(comptime Literal: type, constant: Constant) Literal {
        return .{
            .type_id = @backingInt(constant.type_id),
            .kind = switch (constant.value) {
                .integer, .negative_integer => .Integer,
                .float => .Float,
                .string => .String,
                .boolean => .Boolean,
                .enumeration => .EnumValue,
            },
            .integer = switch (constant.value) {
                .integer, .negative_integer => |magnitude| magnitude,
                else => 0,
            },
            .negative = constant.value == .negative_integer,
            .floating = if (constant.value == .float) constant.value.float else 0,
            .text = if (constant.value == .string) constant.value.string else "",
            .boolean = constant.value == .boolean and constant.value.boolean,
            .enumeration = if (constant.value == .enumeration) constant.value.enumeration else 0,
        };
    }
};
