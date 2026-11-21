const std = @import("std");

pub fn of(comptime Layout: type, comptime Syntax: type) Layout {
    @setEvalBranchQuota(20_000);

    var result: Layout = undefined;

    inline for (@typeInfo(Layout).@"struct".field_names) |name| {
        @field(result, name) = if (comptime std.mem.eql(u8, name, "base"))
            allocation(Syntax)

        else if (comptime std.mem.eql(u8, name, "tables"))
            &tables(std.meta.Child(@FieldType(Layout, name)), Syntax)
        else if (comptime std.mem.eql(u8, name, "function_name"))
            row(@typeInfo(@FieldType(Syntax, name)).optional.child)
        else if (comptime std.mem.eql(u8, name, "tokens") or std.mem.eql(u8, name, "comments"))
            &index(std.meta.Child(@FieldType(Layout, name)), @FieldType(Syntax, name))
        else
            &slice(std.meta.Child(@FieldType(Layout, name)), @FieldType(Syntax, name));
    }

    return result;
}

fn tables(comptime Layout: type, comptime Syntax: type) Layout {
    const Order = std.meta.Child(@FieldType(Syntax, "type_order"));
    var result: Layout = undefined;
    var base = allocation(Order);

    result.order = &slice(std.meta.Child(@FieldType(Layout, "order")), @FieldType(Order, "heads"));

    inline for (.{ "types", "expressions", "blocks" }) |name| {
        const Table = std.meta.Child(@FieldType(Syntax, name));

        @field(result, name) = &columns(std.meta.Child(@FieldType(Layout, name)), Table, std.mem.eql(u8, name, "types"));

        base += allocation(Table);
    }

    result.base = base;

    return result;
}

fn columns(comptime Layout: type, comptime Table: type, comptime rows_owned: bool) Layout {
    var result: Layout = undefined;

    inline for (@typeInfo(Layout).@"struct".field_names) |name| {
        const Item = std.meta.Child(@FieldType(Layout, name));
        const Slice = @FieldType(Table, name);

        @field(result, name) = &(if (rows_owned) index(Item, Slice) else slice(Item, Slice));
    }

    return result;
}

fn slice(comptime Layout: type, comptime Slice: type) Layout {
    const Element = std.meta.Child(Slice);

    return .{ .stride = @sizeOf(Element) + row(Element), .padding = @alignOf(Element) - 1 };
}

fn index(comptime Layout: type, comptime Slice: type) Layout {
    const Element = std.meta.Child(Slice);

    return .{ .stride = @sizeOf(Element), .padding = @alignOf(Element) - 1 };
}

fn row(comptime Value: type) u64 {
    return switch (@typeInfo(Value)) {
        .pointer => |pointer| switch (pointer.size) {
            .one => allocation(pointer.child) + row(pointer.child),
            .slice => 0, // Its length is accounted for by the Source planner.
            else => @compileError("unsupported syntax pointer: " ++ @typeName(Value)),
        },
        .@"struct" => |info| fields: {
            var bytes: u64 = 0;

            inline for (info.field_names) |name| bytes += row(@FieldType(Value, name));

            break :fields bytes;
        },
        .bool, .int, .float, .@"enum" => 0,
        else => @compileError("unsupported syntax row: " ++ @typeName(Value)),
    };
}

fn allocation(comptime Value: type) u64 {
    return @sizeOf(Value) + @alignOf(Value) - 1;
}
