const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Self = @This();

namespace: ?[]const u8 = null,
name: []const u8,
id: ?ir.FunctionId = null,
input_type: ?ir.TypeId = null,
output_type: ?ir.TypeId = null,
intrinsic: ?@import("intrinsic.zig").Operation = null,
pub fn valid(self: @This()) bool {
    return if (self.intrinsic != null)
        self.id == null and self.input_type == null and self.output_type == null

    else
        self.id != null and self.input_type != null and self.output_type != null;
}

pub fn borrow(self: *const @This(), comptime Row: type) Row {
    return .{
        .namespace = self.namespace,
        .name = self.name,
        .id = if (self.id) |id| @backingInt(id) else null,
        .input_type = if (self.input_type) |id| @backingInt(id) else null,
        .output_type = if (self.output_type) |id| @backingInt(id) else null,
        .intrinsic = if (self.intrinsic) |operation| @backingInt(operation) else null,
    };
}

pub const Writable = struct {
    name: zx.memory.WriteColumn,
    namespace: zx.memory.WriteColumn,
    id: zx.memory.WriteColumn,
    input_type: zx.memory.WriteColumn,
    output_type: zx.memory.WriteColumn,
    intrinsic: zx.memory.WriteColumn,
    pub fn borrowRows(rows: []Self) Writable {
        var columns: Writable = undefined;

        inline for (@typeInfo(Writable).@"struct".field_names) |name| {
            @field(columns, name) = zx.memory.borrowWriteColumn(@FieldType(Self, name), name, rows);
        }

        return columns;
    }
    pub fn view(self: *const Writable, comptime Target: type) Target {
        var result: Target = undefined;

        inline for (@typeInfo(Writable).@"struct".field_names) |name| {
            @field(result, name) = @ptrCast(&@field(self, name));
        }

        return result;
    }
};
