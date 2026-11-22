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

const Grow = *const fn (*anyopaque, std.mem.Allocator, usize) std.mem.Allocator.Error!void;

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
            fn grow(column: *anyopaque, allocator: std.mem.Allocator, additional: usize) std.mem.Allocator.Error!void {
                try list(Item, column).ensureUnusedCapacity(allocator, additional);
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

    try operations.*[index](slots(target)[index], borrowAllocator(resource), items);
}

pub fn viewLayout(shape: anytype, output: anytype) std.meta.Child(@TypeOf(output)) {
    const View = std.meta.Child(std.meta.Child(@TypeOf(shape)));

    const Layout = struct {
        const values: []const usize = &viewOffsets(View);
    };

    return @ptrCast(&Layout.values);
}

fn viewOffsets(comptime View: type) [@typeInfo(View).@"struct".field_names.len]usize {
    const names = @typeInfo(View).@"struct".field_names;
    var result: [names.len]usize = undefined;

    for (names, &result) |name, *offset| {
        const Field = @typeInfo(@FieldType(View, name)).pointer;

        if (Field.size != .slice or @sizeOf(@FieldType(View, name)) != @sizeOf([]const u8)) @compileError("Column view fields must be slices");

        offset.* = @offsetOf(View, name);
    }

    return result;
}

pub inline fn readCell(source: *const anyopaque, buffer: *const anyopaque, layout: *const anyopaque, slot: u64) void {
    writeViewCell(buffer, layout, slot, &storageAt(source, slot).items);
}

pub inline fn writeViewCell(buffer: *const anyopaque, layout: *const anyopaque, slot: u64, items: *const []const u8) void {
    const offsets: *const []const usize = @ptrCast(@alignCast(layout));
    const destination: [*]u8 = @ptrCast(@constCast(buffer));
    const offset = offsets.*[@intCast(slot)];
    const bytes = std.mem.asBytes(items);

    @memcpy(destination[offset..][0..bytes.len], bytes);
}

pub fn viewAt(buffer: *const anyopaque, shape: anytype) std.meta.Child(@TypeOf(shape)) {
    return @ptrCast(@alignCast(buffer));
}

const Cell = struct { slot: usize, offset: usize, width: usize };

pub fn borrowRecord(row: anytype, output: anytype) std.meta.Child(@TypeOf(output)) {
    return @ptrCast(row);
}

pub fn zeroRecord(shape: anytype, output: anytype) std.meta.Child(@TypeOf(output)) {
    const Row = std.meta.Child(std.meta.Child(@TypeOf(shape)));

    const empty = struct {
        const value = std.mem.zeroes(Row);
    };

    return @ptrCast(&empty.value);
}

pub fn rowLayout(shape: anytype, output: anytype) std.meta.Child(@TypeOf(output)) {
    const Row = std.meta.Child(std.meta.Child(@TypeOf(shape)));

    return @ptrCast(staticCells(Row, Row));
}

pub fn projectedLayout(shape: anytype, target: anytype, output: anytype) std.meta.Child(@TypeOf(output)) {
    const Row = std.meta.Child(std.meta.Child(@TypeOf(shape)));
    const Destination = std.meta.Child(std.meta.Child(@TypeOf(target)));

    return @ptrCast(staticCells(Row, Destination));
}

fn staticCells(comptime Row: type, comptime Destination: type) *const []const Cell {
    return &struct {
        const values: []const Cell = &rowCells(Row, Destination);
    }.values;
}

fn rowCells(comptime Row: type, comptime Destination: type) [@typeInfo(Row).@"struct".field_names.len]Cell {
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

fn cellsAt(layout: *const anyopaque) []const Cell {
    const cells: *const []const Cell = @ptrCast(@alignCast(layout));

    return cells.*;
}

pub inline fn rowCellCount(layout: *const anyopaque) u64 {
    return cellsAt(layout).len;
}

pub inline fn writeCell(target: *const anyopaque, row: *const anyopaque, layout: *const anyopaque, lane: u64, at: ?u64) void {
    const cell = cellsAt(layout)[@intCast(lane)];
    const storage = storageAt(target, cell.slot);
    const position = storage.items.len + @as(usize, @intCast(at orelse 0));
    const bytes: [*]const u8 = @ptrCast(row);

    std.debug.assert(position < storage.capacity);
    @memcpy(storage.items.ptr[position * cell.width ..][0..cell.width], bytes[cell.offset..][0..cell.width]);

    if (at == null) storage.items.len += 1;
}

fn list(comptime Item: type, storage: *anyopaque) *std.ArrayList(Item) {
    return @ptrCast(@alignCast(storage));
}

pub fn appendU64(resource: *const anyopaque, target: *const anyopaque, value: u64) std.mem.Allocator.Error!void {
    try list(u64, @constCast(target)).append(borrowAllocator(resource), value);
}

pub fn reserveTail(comptime Item: type, resource: *const anyopaque, storage: *const anyopaque, source: *const anyopaque, tail: *const anyopaque, count: u64, limit: u64) std.mem.Allocator.Error!void {
    const column = list(Item, @constCast(storage));

    if (column.items.len > limit or count > limit - column.items.len) return error.OutOfMemory;

    const length = std.math.cast(usize, count) orelse return error.OutOfMemory;
    const existing: *[]const Item = @ptrCast(@alignCast(@constCast(source)));
    const writable: *[]Item = @ptrCast(@alignCast(@constCast(tail)));

    try column.ensureUnusedCapacity(borrowAllocator(resource), length);

    existing.* = column.items;
    writable.* = column.unusedCapacitySlice()[0..length];
}

pub fn copyText(resource: *const anyopaque, source: []const u8) std.mem.Allocator.Error![]const u8 {
    return borrowAllocator(resource).dupe(u8, source);
}

pub fn allocateU32s(resource: *const anyopaque, target: *const anyopaque, count: u64) std.mem.Allocator.Error![]const u32 {
    const output: *[]u32 = @ptrCast(@alignCast(@constCast(target)));
    const size = std.math.cast(usize, count) orelse return error.OutOfMemory;
    const items = try borrowAllocator(resource).alloc(u32, size);

    output.* = items;

    return items;
}

pub fn copyTextViews(resource: *const anyopaque, source: []const []const u8) std.mem.Allocator.Error![]const []const u8 {
    return borrowAllocator(resource).dupe([]const u8, source);
}

pub fn borrowAllocator(resource: *const anyopaque) std.mem.Allocator {
    const allocator: *const std.mem.Allocator = @ptrCast(@alignCast(resource));

    return allocator.*;
}
