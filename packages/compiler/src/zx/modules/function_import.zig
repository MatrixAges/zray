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
    if (self.intrinsic != null) return self.id == null and self.input_type == null and self.output_type == null;

    return self.id != null and self.input_type != null and self.output_type != null;
}

pub fn borrow(self: *const @This(), comptime Row: type) Row {
    var row: Row = undefined;

    row.id = if (self.id) |id| @backingInt(id) else null;
    row.input_type = if (self.input_type) |id| @backingInt(id) else null;
    row.output_type = if (self.output_type) |id| @backingInt(id) else null;
    row.intrinsic = if (self.intrinsic) |operation| @backingInt(operation) else null;

    if (@hasField(Row, "namespace")) row.namespace = self.namespace;
    if (@hasField(Row, "name")) row.name = self.name;

    return row;
}

pub fn Output(comptime Target: type) type {
    return zx.memory.RowOutput(Self, Target, .{
        .name = &.{"name"},
        .namespace = &.{"namespace"},
        .id = &.{"id"},
        .input_type = &.{"input_type"},
        .output_type = &.{"output_type"},
        .intrinsic = &.{"intrinsic"},
    });
}

pub const Readable = struct {
    id: zx.memory.ReadColumn,
    input_type: zx.memory.ReadColumn,
    output_type: zx.memory.ReadColumn,
    intrinsic: zx.memory.ReadColumn,
    pub fn borrowRows(rows: []const Self) Readable {
        const memory = zx.memory;

        return .{
            .id = memory.borrowOptionalU32Column("id", rows),
            .input_type = memory.borrowOptionalU32Column("input_type", rows),
            .output_type = memory.borrowOptionalU32Column("output_type", rows),
            .intrinsic = memory.borrowOptionalU8Column("intrinsic", rows),
        };
    }
    pub fn view(self: *const Readable, comptime Target: type) Target {
        var result: Target = undefined;

        inline for (@typeInfo(Target).@"struct".field_names) |name| {
            if (comptime std.mem.eql(u8, name, "count")) {
                @field(result, name) = self.id.count;
            } else {
                @field(result, name) = @ptrCast(&@field(self, name));
            }
        }

        return result;
    }
};

pub const Columns = struct {
    namespace: zx.memory.ReadColumn,
    name: zx.memory.TextColumn,
    ports: Readable,
    pub fn borrow(rows: []const Self) Columns {
        return .{
            .namespace = zx.memory.borrowReadColumn(?[]const u8, "namespace", rows),
            .name = zx.memory.borrowTextColumn("name", rows),
            .ports = Readable.borrowRows(rows),
        };
    }
    pub fn view(self: *const Columns, comptime Target: type) Target {
        return .{
            .namespace = @ptrCast(&self.namespace),
            .name = @ptrCast(&self.name),
            .id = @ptrCast(&self.ports.id),
            .input_type = @ptrCast(&self.ports.input_type),
            .output_type = @ptrCast(&self.ports.output_type),
            .intrinsic = @ptrCast(&self.ports.intrinsic),
            .count = self.name.count,
        };
    }
};
