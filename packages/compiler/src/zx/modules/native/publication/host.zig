const std = @import("std");
const zx = @import("zx");
const FunctionImport = @import("../../function_import.zig");
const TypeTail = @import("../../../analysis/semantic/merging/publication/view.zig");

pub fn ownBindings(allocator: std.mem.Allocator, rows: anytype) std.mem.Allocator.Error![]const FunctionImport {
    const bindings = try allocator.alloc(FunctionImport, rows.len);

    for (rows, bindings) |row, *binding| {
        binding.* = .{
            .name = row.name,
            .id = @fromBackingInt(row.id),
            .input_type = @fromBackingInt(row.input_type),
            .output_type = @fromBackingInt(row.output_type),
        };
    }

    return bindings;
}

pub fn appendColumnsAssumeCapacity(storage: anytype, rows: anytype) void {
    const Storage = std.meta.Child(@TypeOf(storage));

    inline for (@typeInfo(Storage).@"struct".field_names) |name| {
        const column = &@field(storage, name);
        const Item = std.meta.Elem(@TypeOf(column.items));

        for (rows) |row| column.appendAssumeCapacity(zx.columns.view(Item, @field(row, name)));
    }
}

pub fn publishTypes(tail: *TypeTail) void {
    for (tail.ranges, 0..) |_, index| zx.memory.publishColumnRange(@ptrCast(&tail.ranges), index);
    for (tail.nominal_ranges, 0..) |_, index| zx.memory.publishColumnRange(@ptrCast(&tail.nominal_ranges), index);

    tail.copied[0] = 0;
}
