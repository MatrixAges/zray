const std = @import("std");
const ir = @import("zx").ir;
const Builder = @import("../../builder.zig");
const abi = @import("../abi.zig");
const Input = std.meta.Child(@FieldType(abi.Request, "literals"));
const Column = std.meta.Child(std.meta.Child(@FieldType(Input, "columns")));
const Text = std.meta.Child(@typeInfo(@FieldType(Input, "owned_text")).optional.child);
const Bases = std.meta.Child(@FieldType(abi.Payload, "literals"));
const names = @typeInfo(Bases).@"struct".field_names;

pub const Frame = struct {
    input: Input = undefined,
    bases: Bases = undefined,
    views: [names.len][]u8 = undefined,
    columns: [names.len]Column = undefined,
    pointers: [names.len]*const Column = undefined,
    strings: [][]const u8 = undefined,
    text: Text = undefined,
    /// Inlining removes binding references. Literal payloads keep their source order.
    pub fn prepare(self: *Frame, builder: *Builder, source: *const ir.ExpressionTable, borrow_text: bool) Builder.Error!bool {
        const storage = &builder.expressions;
        var count: usize = 0;
        var owned: ?*const Text = null;

        inline for (names) |name| {
            const values = @field(source, name);
            const target = &@field(storage, name);

            @field(self.bases, name) = target.items.len;

            if (values.len != 0) {
                try storage.reserveColumns(builder.allocator, &.{name}, values.len);

                const tail = target.unusedCapacitySlice()[0..values.len];
                const own_text = comptime std.mem.eql(u8, name, "strings");

                if (own_text and !borrow_text) {
                    self.strings = tail;
                    self.text = .{ .allocator = @ptrCast(&builder.allocator), .source = values, .target = @ptrCast(&self.strings) };
                    owned = &self.text;
                } else {
                    self.views[count] = std.mem.sliceAsBytes(tail);
                    self.columns[count] = .{ .source = std.mem.sliceAsBytes(values), .target = @ptrCast(&self.views[count]) };
                    self.pointers[count] = &self.columns[count];
                    count += 1;
                }
            }
        }

        self.input = .{ .columns = self.pointers[0..count], .owned_text = owned };

        return count != 0 or owned != null;
    }
    pub fn commit(storage: *ir.ExpressionStorage, source: *const ir.ExpressionTable) void {
        inline for (names) |name| @field(storage, name).items.len += @field(source, name).len;
    }
};
