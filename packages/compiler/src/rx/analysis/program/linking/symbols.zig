const std = @import("std");
const ir = @import("zx").ir;
const Builder = @import("../builder.zig");
const text = @import("literals/text.zig");
const Request = @import("abi.zig").Request;
const Input = std.meta.Child(@typeInfo(@FieldType(Request, "symbols")).optional.child);
const fields = @typeInfo(ir.SymbolStorage).@"struct".field_names;
const metadata = .{ "types", "span_start", "span_end" };

pub const Frame = struct {
    input: Input = undefined,
    names: std.meta.Child(@FieldType(Input, "names")) = undefined,
    ownership: std.meta.Child(@FieldType(Input, "ownership")) = undefined,
    pub fn prepare(self: *Frame, builder: *Builder, source: *const ir.SymbolTable, first: usize, borrow_names: bool) Builder.Error!bool {
        const length = source.count() - first;
        const storage = &builder.symbols;

        if (length == 0) return false;
        if (length > std.math.maxInt(u32) - storage.count()) return error.OutOfMemory;

        inline for (fields) |name| {
            try @field(storage, name).ensureUnusedCapacity(builder.allocator, length);
        }

        self.names = .{
            .values = source.names[first..],
            .borrowed = borrow_names,
        };

        self.ownership = .{
            .count = length,
            .copy_tag = @backingInt(ir.SymbolTable.Ownership.Copy),
        };

        self.input = .{
            .names = &self.names,
            .types = source.types[first..],
            .span_start = source.span_start[first..],
            .span_end = source.span_end[first..],
            .ownership = &self.ownership,
        };

        return true;
    }
};

pub fn publish(builder: *Builder, rows: anytype) Builder.Error!void {
    const storage = &builder.symbols;
    const count = rows.names.values.len;

    try text.write(builder.allocator, storage.names.unusedCapacitySlice()[0..count], rows.names);

    inline for (metadata) |name| {
        @field(storage, name).appendSliceAssumeCapacity(@field(rows, name));
    }

    storage.ownership.appendSliceAssumeCapacity(@ptrCast(rows.ownership));

    storage.names.items.len += count;
}
