const std = @import("std");
const ir = @import("zx").ir;
const Builder = @import("../builder.zig");
const literal = @import("literals/host.zig");
const Request = @import("abi.zig").Request;
const Input = std.meta.Child(@typeInfo(@FieldType(Request, "symbols")).optional.child);
const fields = @typeInfo(ir.SymbolStorage).@"struct".field_names;
const metadata = .{ "types", "span_start", "span_end" };

pub const Frame = struct {
    input: Input = undefined,
    views: [metadata.len + 1][]u8 = undefined,
    columns: [metadata.len + 1][]const u8 = undefined,
    ownership_view: std.meta.Child(@FieldType(Input, "ownership")) = undefined,
    pub fn prepare(self: *Frame, builder: *Builder, source: *const ir.SymbolTable, first: usize, borrow_names: bool) Builder.Error!bool {
        const length = source.count() - first;
        const storage = &builder.symbols;

        if (length == 0) return false;
        if (length > std.math.maxInt(u32) - storage.count()) return error.OutOfMemory;

        inline for (fields) |name| {
            try @field(storage, name).ensureUnusedCapacity(builder.allocator, length);
        }

        const source_names = source.names[first..];

        if (borrow_names) {
            self.views[metadata.len] = std.mem.sliceAsBytes(storage.names.unusedCapacitySlice()[0..length]);
            self.columns[metadata.len] = std.mem.sliceAsBytes(source_names);
        }

        inline for (metadata, 0..) |name, index| {
            self.views[index] = std.mem.sliceAsBytes(@field(storage, name).unusedCapacitySlice()[0..length]);
            self.columns[index] = std.mem.sliceAsBytes(@field(source, name)[first..]);
        }

        self.ownership_view = .{
            .count = length,
            .copy_tag = @backingInt(ir.SymbolTable.Ownership.Copy),
        };

        self.input = .{
            .columns = self.columns[0 .. metadata.len + @intFromBool(borrow_names)],
            .owned_text = if (borrow_names) null else source_names,
            .ownership = &self.ownership_view,
        };

        return true;
    }
    pub fn commit(self: *const Frame, builder: *Builder, rows: anytype) Builder.Error!void {
        const storage = &builder.symbols;
        const count = rows.ownership.len;

        literal.copyColumns(self.views[0..rows.columns.len], rows.columns);

        if (rows.owned_text) |text| try literal.ownText(builder.allocator, storage.names.unusedCapacitySlice()[0..count], text);

        @memcpy(std.mem.sliceAsBytes(storage.ownership.unusedCapacitySlice()[0..count]), rows.ownership);
        inline for (fields) |name| @field(storage, name).items.len += count;
    }
};
