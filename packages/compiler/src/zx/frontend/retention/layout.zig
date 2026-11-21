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
        else
            &slice(std.meta.Child(@FieldType(Layout, name)), @FieldType(Syntax, name));
    }

    return result;
}

fn tables(comptime Layout: type, comptime Syntax: type) Layout {
    var result: Layout = undefined;
    var base: u64 = 0;

    inline for (.{ "types", "type_order", "expressions", "blocks" }) |name| {
        const Table = std.meta.Child(@FieldType(Syntax, name));
        const key = if (std.mem.eql(u8, name, "type_order")) "order" else name;

        @field(result, key) = &columns(std.meta.Child(@FieldType(Layout, key)), Table);

        base += allocation(Table);
    }

    result.base = base;

    return result;
}

fn columns(comptime Layout: type, comptime Table: type) Layout {
    var result: Layout = undefined;

    inline for (@typeInfo(Layout).@"struct".field_names) |name| {
        @field(result, name) = &slice(std.meta.Child(@FieldType(Layout, name)), @FieldType(Table, name));
    }

    return result;
}

fn slice(comptime Layout: type, comptime Slice: type) Layout {
    const Element = std.meta.Child(Slice);

    return .{ .stride = @sizeOf(Element) + row(Element), .padding = @alignOf(Element) - 1 };
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
