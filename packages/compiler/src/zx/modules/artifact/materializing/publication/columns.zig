const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;

pub fn borrow(comptime Layout: type, source: anytype) Layout {
    var result: Layout = undefined;

    inline for (@typeInfo(Layout).@"struct".field_names) |name| {
        if (comptime std.mem.eql(u8, name, "zx_origin")) {
            @field(result, name) = null;
        } else {
            const Field = @FieldType(Layout, name);

            @field(result, name) = .{
                .items = zx.columns.slice(@FieldType(Field, "items"), @field(source, name)),
                .storage = .plain,
            };
        }
    }

    return result;
}

pub fn Tail(comptime Target: type) type {
    const Row = std.meta.Child(@typeInfo(@FieldType(Target, "shape")).optional.child);

    return struct {
        const Self = @This();

        slots: [@typeInfo(Row).@"struct".field_names.len]*anyopaque,
        storage: zx.memory.ColumnSet,
        pub fn init(self: *Self, destination: *ir.FunctionStorage) void {
            self.slots = zx.memory.bindColumnSet(Row, true, destination);
            self.storage = &self.slots;
        }
    };
}

pub fn body(comptime Layout: type, storage: *ir.FunctionStorage, count: usize) Layout {
    var result: Layout = undefined;

    inline for (@typeInfo(Layout).@"struct".field_names) |name| {
        if (comptime std.mem.eql(u8, name, "zx_origin")) {
            @field(result, name) = null;
        } else {
            const Field = @FieldType(Layout, name);
            const entries: @FieldType(ir.FunctionTable, name) = @field(storage, name).unusedCapacitySlice()[0..count];

            @field(result, name) = .{
                .items = zx.columns.slice(@FieldType(Field, "items"), entries),
                .storage = .exclusive,
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

pub fn view(comptime Layout: type, source: anytype) Layout {
    var result: Layout = undefined;

    inline for (@typeInfo(Layout).@"struct".field_names) |name| {
        const column = @field(source, name);
        const entries = if (@typeInfo(@TypeOf(column)) == .pointer) column else column.items;

        @field(result, name) = zx.columns.slice(@FieldType(Layout, name), entries);
    }

    return result;
}
