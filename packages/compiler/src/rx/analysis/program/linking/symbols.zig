const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Builder = @import("../builder.zig");
const Request = @import("abi.zig").Request;
const Input = std.meta.Child(@FieldType(Request, "symbols"));
const Column = std.meta.Child(std.meta.Child(@FieldType(Input, "columns")));
const Text = std.meta.Child(@typeInfo(@FieldType(Input, "owned_text")).optional.child);
const fields = @typeInfo(ir.SymbolStorage).@"struct".field_names;
const metadata = .{ "types", "span_start", "span_end" };

pub const Frame = struct {
    input: Input = undefined,
    views: [metadata.len + 1][]u8 = undefined,
    columns: [metadata.len + 1]Column = undefined,
    pointers: [metadata.len + 1]*const Column = undefined,
    names: [][]const u8 = undefined,
    ownership: []u8 = undefined,
    text: Text = undefined,
    ownership_view: std.meta.Child(@FieldType(Input, "ownership")) = undefined,
    length_slots: [fields.len]*usize = undefined,
    lengths: zx.memory.ColumnLengths = undefined,
    pub fn prepare(self: *Frame, builder: *Builder, source: *const ir.SymbolTable, first: usize, borrow_names: bool) Builder.Error!bool {
        const length = source.count() - first;
        const storage = &builder.symbols;

        if (length == 0) return false;
        if (length > std.math.maxInt(u32) - storage.count()) return error.OutOfMemory;

        inline for (fields) |name| {
            try @field(storage, name).ensureUnusedCapacity(builder.allocator, length);
        }

        self.names = storage.names.unusedCapacitySlice()[0..length];

        const source_names = source.names[first..];
        const name_index = metadata.len;

        if (borrow_names) {
            self.views[name_index] = std.mem.sliceAsBytes(self.names);
            self.columns[name_index] = .{ .source = std.mem.sliceAsBytes(source_names), .target = @ptrCast(&self.views[name_index]) };
            self.pointers[name_index] = &self.columns[name_index];
        } else {
            self.text = .{ .allocator = @ptrCast(&builder.allocator), .source = source_names, .target = @ptrCast(&self.names) };
        }

        inline for (metadata, 0..) |name, index| {
            self.views[index] = std.mem.sliceAsBytes(@field(storage, name).unusedCapacitySlice()[0..length]);
            self.columns[index] = .{ .source = std.mem.sliceAsBytes(@field(source, name)[first..]), .target = @ptrCast(&self.views[index]) };
            self.pointers[index] = &self.columns[index];
        }

        comptime {
            if (@sizeOf(ir.SymbolTable.Ownership) != 1) @compileError("symbol ownership must occupy one byte");
        }

        self.ownership = std.mem.sliceAsBytes(storage.ownership.unusedCapacitySlice()[0..length]);
        self.length_slots = zx.memory.borrowColumnLengths(storage);
        self.lengths = &self.length_slots;

        self.input = .{
            .columns = self.pointers[0 .. metadata.len + @intFromBool(borrow_names)],
            .owned_text = if (borrow_names) null else &self.text,
            .ownership = &self.ownership_view,
            .lengths = @ptrCast(&self.lengths),
        };

        self.ownership_view = .{
            .rows = @ptrCast(&self.ownership),
            .count = length,
            .copy_tag = @backingInt(ir.SymbolTable.Ownership.Copy),
        };

        return true;
    }
};
