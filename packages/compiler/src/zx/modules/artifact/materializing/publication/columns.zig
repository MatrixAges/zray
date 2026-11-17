const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;

pub fn borrow(comptime Layout: type, source: anytype, comptime writable: bool) Layout {
    var result: Layout = undefined;

    inline for (@typeInfo(Layout).@"struct".field_names) |name| {
        if (comptime std.mem.eql(u8, name, "zx_origin")) {
            @field(result, name) = null;
        } else {
            const Field = @FieldType(Layout, name);

            @field(result, name) = .{
                .items = zx.columns.slice(@FieldType(Field, "items"), @field(source, name)),
                .storage = if (writable) .owned else .plain,
            };
        }
    }

    return result;
}

pub fn checkBorrow(initial: anytype, returned: @TypeOf(initial)) void {
    inline for (@typeInfo(@TypeOf(initial)).@"struct".field_names) |name| {
        if (comptime @hasField(ir.FunctionTable, name)) {
            std.debug.assert(@field(returned, name).items.ptr == @field(initial, name).items.ptr);
        }
    }
}

pub fn publish(comptime WriteColumns: type, storage: *ir.FunctionStorage, source: ir.FunctionTable, count: usize) void {
    if (count == 0) return;

    inline for (@typeInfo(ir.FunctionTable).@"struct".field_names) |name| {
        if (comptime !@hasField(WriteColumns, name)) {
            @memcpy(@field(storage, name).unusedCapacitySlice()[0..count], @field(source, name)[0..count]);
        }
    }

    storage.commitTail(count);
}
