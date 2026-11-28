const std = @import("std");
const ir = @import("zx").ir;
const Builder = @import("../../builder.zig");
const abi = @import("../abi.zig");
const text = @import("text.zig");
const Input = std.meta.Child(@typeInfo(@FieldType(abi.Request, "literals")).optional.child);
const Bases = std.meta.Child(@FieldType(abi.Payload, "literals"));
const names = @typeInfo(Bases).@"struct".field_names;

pub const Frame = struct {
    input: Input = undefined,
    bases: Bases = undefined,
    strings: std.meta.Child(@FieldType(Input, "strings")) = undefined,
    pub fn prepare(self: *Frame, builder: *Builder, source: *const ir.ExpressionTable, borrow_text: bool) Builder.Error!bool {
        const storage = &builder.expressions;
        var populated = false;

        inline for (names) |name| {
            const values = @field(source, name);
            const target = &@field(storage, name);

            @field(self.bases, name) = target.items.len;

            if (values.len != 0) {
                try storage.reserveColumns(builder.allocator, &.{name}, values.len);

                populated = true;
            }

            if (comptime std.mem.eql(u8, name, "strings")) {
                self.strings = .{ .values = values, .borrowed = borrow_text };
                self.input.strings = &self.strings;
            } else {
                @field(self.input, name) = values;
            }
        }

        return populated;
    }
};

pub fn publish(builder: *Builder, rows: *const Input) Builder.Error!void {
    const storage = &builder.expressions;
    const strings = rows.strings.values.len;

    try text.write(builder.allocator, storage.strings.unusedCapacitySlice()[0..strings], rows.strings);

    inline for (names) |name| {
        if (comptime !std.mem.eql(u8, name, "strings")) {
            @field(storage, name).appendSliceAssumeCapacity(@field(rows, name));
        }
    }

    storage.strings.items.len += strings;
}
