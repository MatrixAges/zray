const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Builder = @import("../../builder.zig");
const generated = @import("generated_rx_link_literals");

pub const Bases = struct {
    integers: usize,
    negative_integers: usize,
    floats: usize,
    strings: usize,
    booleans: usize,
    enumerations: usize,
    errors: usize,
};

/// Inlining removes input binding references and projections. Literal rows keep their payload order.
pub fn publish(builder: *Builder, source: *const ir.ExpressionTable, borrow_text: bool) Builder.Error!Bases {
    const Input = std.meta.Child(generated.Input);
    const Column = std.meta.Child(std.meta.Child(@FieldType(Input, "columns")));
    const Text = std.meta.Child(@typeInfo(@FieldType(Input, "owned_text")).optional.child);
    const names = @typeInfo(Bases).@"struct".field_names;
    const storage = &builder.expressions;
    var bases: Bases = undefined;
    var views: [names.len][]u8 = undefined;
    var columns: [names.len]Column = undefined;
    var pointers: [names.len]*const Column = undefined;
    var strings: [][]const u8 = undefined;
    var text: ?Text = null;
    var count: usize = 0;

    inline for (names) |name| {
        const values = @field(source, name);
        const target = &@field(storage, name);

        @field(bases, name) = target.items.len;

        if (values.len != 0) {
            try storage.reserveColumns(builder.allocator, &.{name}, values.len);

            const tail = target.unusedCapacitySlice()[0..values.len];
            const own_text = comptime std.mem.eql(u8, name, "strings");

            if (own_text and !borrow_text) {
                strings = tail;
                text = .{ .source = values, .target = @ptrCast(&strings) };
            } else {
                views[count] = std.mem.sliceAsBytes(tail);
                columns[count] = .{ .source = std.mem.sliceAsBytes(values), .target = @ptrCast(&views[count]) };
                pointers[count] = &columns[count];
                count += 1;
            }
        }
    }

    if (count == 0 and text == null) return bases;

    const input: Input = .{ .columns = pointers[0..count], .owned_text = if (text) |*owned| owned else null };

    zx.columns.invoke(generated.executeValue, builder.allocator, &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidModule,
    };

    inline for (names) |name| @field(storage, name).items.len += @field(source, name).len;

    return bases;
}
