const std = @import("std");

pub fn of(comptime Layout: type, comptime Syntax: type) Layout {
    @setEvalBranchQuota(20_000);

    var result: Layout = undefined;

    inline for (@typeInfo(Layout).@"struct".field_names) |name| {
        @field(result, name) = if (comptime std.mem.eql(u8, name, "base"))
            allocation(Syntax) + if (@hasField(Syntax, "function_name"))
                allocation(std.meta.Child(std.meta.Child(@FieldType(Syntax, "function_name"))))

            else
                0

        else if (comptime std.mem.eql(u8, name, "tables"))
            &tables(std.meta.Child(@FieldType(Layout, name)), Syntax)
        else if (comptime std.mem.eql(u8, name, "constants"))
            &constantIndex(std.meta.Child(@FieldType(Layout, name)), @FieldType(Syntax, name))
        else
            &index(std.meta.Child(@FieldType(Layout, name)), @FieldType(Syntax, name));
    }

    return result;
}

fn tables(comptime Layout: type, comptime Syntax: type) Layout {
    const Order = std.meta.Child(@FieldType(Syntax, "type_order"));
    var result: Layout = undefined;
    var base = allocation(Order);

    result.order = &index(std.meta.Child(@FieldType(Layout, "order")), @FieldType(Order, "heads"));

    inline for (.{ "types", "expressions", "blocks" }) |name| {
        const Table = std.meta.Child(@FieldType(Syntax, name));

        @field(result, name) = &columns(std.meta.Child(@FieldType(Layout, name)), Table);

        base += allocation(Table);
    }

    result.base = base;

    return result;
}

fn columns(comptime Layout: type, comptime Table: type) Layout {
    var result: Layout = undefined;

    inline for (@typeInfo(Layout).@"struct".field_names) |name| {
        const Item = std.meta.Child(@FieldType(Layout, name));
        const Slice = @FieldType(Table, name);

        @field(result, name) = &index(Item, Slice);
    }

    return result;
}

fn constantIndex(comptime Layout: type, comptime Slice: type) Layout {
    const Element = std.meta.Child(Slice);
    const Constant = std.meta.Child(Element);
    const Span = std.meta.Child(@FieldType(Constant, "span"));

    return .{
        .stride = @sizeOf(Element) + @sizeOf(Constant) + 2 * allocation(Span),
        .padding = (@alignOf(Element) - 1) + (@alignOf(Constant) - 1),
    };
}

fn index(comptime Layout: type, comptime Slice: type) Layout {
    const Element = std.meta.Child(Slice);
    var stride: u64 = @sizeOf(Element);
    var padding: u64 = @alignOf(Element) - 1;

    if (comptime @typeInfo(Element) == .pointer) {
        const Row = std.meta.Child(Element);

        stride += @sizeOf(Row);
        padding += @alignOf(Row) - 1;

        inline for (@typeInfo(Row).@"struct".field_names) |field_name| {
            const Field = @FieldType(Row, field_name);

            if (comptime @typeInfo(Field) == .pointer) {
                const Sub = std.meta.Child(Field);
                stride += @sizeOf(Sub);
                padding += @alignOf(Sub) - 1;
            }
        }
    }

    return .{ .stride = stride, .padding = padding };
}

fn allocation(comptime Value: type) u64 {
    return @sizeOf(Value) + @alignOf(Value) - 1;
}
