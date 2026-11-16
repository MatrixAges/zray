const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Builder = @import("../builder.zig");
const rule = @import("generated_rx_link_fresh_symbols");
const Input = std.meta.Child(rule.Input);
const Column = std.meta.Child(std.meta.Child(@FieldType(Input, "columns")));
const Text = std.meta.Child(@typeInfo(@FieldType(Input, "owned_text")).optional.child);

pub fn publish(builder: *Builder, source: ir.SymbolTable, first: usize, borrow_names: bool) Builder.Error!void {
    const length = source.count() - first;
    const storage = &builder.symbols;

    if (length == 0) return;
    if (length > std.math.maxInt(u32) - storage.count()) return error.OutOfMemory;

    const fields = @typeInfo(ir.SymbolStorage).@"struct".field_names;

    inline for (fields) |name| {
        try @field(storage, name).ensureUnusedCapacity(builder.allocator, length);
    }

    const names = storage.names.unusedCapacitySlice()[0..length];
    const source_names = source.names[first..];
    const name_bytes = std.mem.sliceAsBytes(names);
    const borrowed: Column = .{ .source = std.mem.sliceAsBytes(source_names), .target = @ptrCast(&name_bytes) };
    const owned: Text = .{ .source = source_names, .target = @ptrCast(&names) };
    const metadata = .{ "types", "span_start", "span_end" };
    var views: [metadata.len][]u8 = undefined;
    var columns: [metadata.len]Column = undefined;
    var pointers: [metadata.len + 1]*const Column = undefined;

    inline for (metadata, 0..) |name, index| {
        views[index] = std.mem.sliceAsBytes(@field(storage, name).unusedCapacitySlice()[0..length]);
        columns[index] = .{ .source = std.mem.sliceAsBytes(@field(source, name)[first..]), .target = @ptrCast(&views[index]) };
        pointers[index] = &columns[index];
    }

    pointers[metadata.len] = &borrowed;

    comptime {
        if (@sizeOf(ir.SymbolTable.Ownership) != 1) @compileError("symbol ownership must occupy one byte");
    }

    const ownership = std.mem.sliceAsBytes(storage.ownership.unusedCapacitySlice()[0..length]);

    const input: Input = .{
        .columns = pointers[0 .. metadata.len + @intFromBool(borrow_names)],
        .owned_text = if (borrow_names) null else &owned,
        .ownership = &.{ .rows = @ptrCast(&ownership), .count = length, .copy_tag = @backingInt(ir.SymbolTable.Ownership.Copy) },
    };

    zx.columns.invoke(rule.executeValue, builder.allocator, &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidModule,
    };

    inline for (fields) |name| @field(storage, name).items.len += length;
}
