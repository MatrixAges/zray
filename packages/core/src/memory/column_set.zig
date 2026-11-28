const std = @import("std");
pub const ColumnSet = []const *anyopaque;

pub inline fn erase(target: anytype) *std.ArrayList(u8) {
    comptime {
        const Storage = std.meta.Child(@TypeOf(target));
        const Erased = std.ArrayList(u8);

        std.debug.assert(@sizeOf(Storage) == @sizeOf(Erased) and @alignOf(Storage) == @alignOf(Erased));
        std.debug.assert(@offsetOf(Storage, "items") == @offsetOf(Erased, "items"));
        std.debug.assert(@offsetOf(Storage, "capacity") == @offsetOf(Erased, "capacity"));
    }

    return @ptrCast(target);
}

pub fn bind(comptime View: type, comptime scalar: bool, storage: anytype) [@typeInfo(View).@"struct".field_names.len]*anyopaque {
    const names = @typeInfo(View).@"struct".field_names;
    var result: [names.len]*anyopaque = undefined;

    inline for (names, &result) |name, *item| {
        const native = &@field(storage, name);
        const Field = @FieldType(View, name);
        const Item = if (scalar) Field else std.meta.Elem(Field);
        const List = std.ArrayList(Item);

        comptime {
            const Original = std.meta.Child(@TypeOf(native));

            if (@sizeOf(List) != @sizeOf(Original) or @alignOf(List) != @alignOf(Original) or
                @offsetOf(List, "items") != @offsetOf(Original, "items") or @offsetOf(List, "capacity") != @offsetOf(Original, "capacity") or
                @sizeOf(Item) != @sizeOf(std.meta.Elem(@FieldType(Original, "items"))) or
                @alignOf(Item) != @alignOf(std.meta.Elem(@FieldType(Original, "items")))) @compileError("Incompatible native column storage");

            const NativeItem = std.meta.Elem(@FieldType(Original, "items"));

            if (@typeInfo(Item) == .@"enum" and @typeInfo(NativeItem) == .@"enum") {
                if (!std.meta.eql(@typeInfo(Item).@"enum".field_names, @typeInfo(NativeItem).@"enum".field_names)) @compileError("Incompatible native enum column");

                for (@typeInfo(Item).@"enum".field_names) |tag| {
                    if (@backingInt(@field(Item, tag)) != @backingInt(@field(NativeItem, tag))) @compileError("Incompatible native enum discriminant");
                }
            }
        }

        item.* = native;
    }

    return result;
}

fn slots(target: *const anyopaque) ColumnSet {
    const columns: *const ColumnSet = @ptrCast(@alignCast(target));

    return columns.*;
}

fn storageAt(target: *const anyopaque, slot: u64) *std.ArrayList(u8) {
    return list(u8, slots(target)[@intCast(slot)]);
}

pub inline fn slotCount(target: *const anyopaque) u64 {
    return slots(target).len;
}

pub inline fn firstLength(target: *const anyopaque) u64 {
    return storageAt(target, 0).items.len;
}

const Grow = *const fn (*anyopaque, std.mem.Allocator, usize) bool;

pub fn growth(shape: anytype, output: anytype) std.meta.Child(@TypeOf(output)) {
    const Row = std.meta.Child(std.meta.Child(@TypeOf(shape)));

    const Layout = struct {
        const values: []const Grow = &growers(Row);
    };

    return @ptrCast(&Layout.values);
}

fn growers(comptime Row: type) [@typeInfo(Row).@"struct".field_names.len]Grow {
    const names = @typeInfo(Row).@"struct".field_names;
    var result: [names.len]Grow = undefined;

    for (names, &result) |name, *operation| {
        const Item = @FieldType(Row, name);

        const Typed = struct {
            fn grow(column: *anyopaque, allocator: std.mem.Allocator, additional: usize) bool {
                list(Item, column).ensureUnusedCapacity(allocator, additional) catch return false;

                return true;
            }
        };

        operation.* = Typed.grow;
    }

    return result;
}

pub fn reserveCell(resource: *const anyopaque, target: *const anyopaque, layout: *const anyopaque, slot: u64, additional: u64) std.mem.Allocator.Error!void {
    const operations: *const []const Grow = @ptrCast(@alignCast(layout));
    const index: usize = @intCast(slot);
    const items = std.math.cast(usize, additional) orelse return error.OutOfMemory;

    if (!operations.*[index](slots(target)[index], borrowAllocator(resource), items)) return error.OutOfMemory;
}

pub fn borrowRecord(row: anytype) []const u8 {
    return std.mem.asBytes(row);
}

pub fn zeroRecord(shape: anytype) []const u8 {
    const Row = std.meta.Child(std.meta.Child(@TypeOf(shape)));

    const empty = struct {
        const value = std.mem.zeroes(Row);
    };

    return std.mem.asBytes(&empty.value);
}

pub fn rowLayout(shape: anytype, output: anytype) std.meta.Child(@TypeOf(output)) {
    const Row = std.meta.Child(std.meta.Child(@TypeOf(shape)));

    return staticCells(Row, Row, std.meta.Child(@TypeOf(output)));
}

pub fn projectedLayout(shape: anytype, target: anytype, output: anytype) std.meta.Child(@TypeOf(output)) {
    const Row = std.meta.Child(std.meta.Child(@TypeOf(shape)));
    const Destination = std.meta.Child(std.meta.Child(@TypeOf(target)));

    return staticCells(Row, Destination, std.meta.Child(@TypeOf(output)));
}

fn staticCells(comptime Row: type, comptime Destination: type, comptime Layout: type) Layout {
    const Cell = std.meta.Child(std.meta.Elem(Layout));

    const Cells = struct {
        const values = rowCells(Row, Destination, Cell);

        const pointers = block: {
            var result: [values.len]*const Cell = undefined;

            for (&values, &result) |*value, *pointer| pointer.* = value;

            break :block result;
        };
    };

    return &Cells.pointers;
}

fn rowCells(comptime Row: type, comptime Destination: type, comptime Cell: type) [@typeInfo(Row).@"struct".field_names.len]Cell {
    const names = @typeInfo(Row).@"struct".field_names;
    var result: [names.len]Cell = undefined;

    for (names, &result) |name, *cell| {
        const Field = @FieldType(Row, name);

        if (Field != @FieldType(Destination, name)) @compileError("Incompatible record projection field " ++ name);

        cell.* = .{
            .slot = std.meta.fieldIndex(Destination, name).?,
            .offset = @offsetOf(Row, name),
            .width = @sizeOf(Field),
        };
    }

    return result;
}

pub inline fn writeCell(target: *const anyopaque, row: []const u8, slot: u64, offset: u64, width: u64, at: ?u64) void {
    const storage = storageAt(target, slot);
    const position = storage.items.len + @as(usize, @intCast(at orelse 0));
    const size: usize = @intCast(width);

    std.debug.assert(position < storage.capacity);
    @memcpy(storage.items.ptr[position * size ..][0..size], row[@intCast(offset)..][0..size]);

    if (at == null) storage.items.len += 1;
}

fn list(comptime Item: type, storage: *anyopaque) *std.ArrayList(Item) {
    return @ptrCast(@alignCast(storage));
}

pub fn borrowAllocator(resource: *const anyopaque) std.mem.Allocator {
    const allocator: *const std.mem.Allocator = @ptrCast(@alignCast(resource));

    return allocator.*;
}
