const std = @import("std");

pub fn of(comptime Layout: type, comptime Syntax: type) Layout {
    @setEvalBranchQuota(20_000);

    var result: Layout = undefined;

    inline for (@typeInfo(Layout).@"struct".field_names) |name| {
        @field(result, name) = if (comptime std.mem.eql(u8, name, "base"))
            allocation(Syntax)

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
    const alignment = @alignOf(Element);

    return .{ .stride = @sizeOf(Element) + allocation(std.meta.Child(Element)), .padding = alignment - 1 };
}

fn index(comptime Layout: type, comptime Slice: type) Layout {
    const Element = std.meta.Child(Slice);

    return .{ .stride = @sizeOf(Element), .padding = @alignOf(Element) - 1 };
}

fn allocation(comptime Value: type) u64 {
    return @sizeOf(Value) + @alignOf(Value) - 1;
}
