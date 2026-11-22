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

pub fn reserve(resource: *const anyopaque, target: *const anyopaque, shape: anytype, additional: u64, limit: u64) std.mem.Allocator.Error!void {
    const allocator = borrowAllocator(resource);
    const columns: *const ColumnSet = @ptrCast(@alignCast(target));
    const View = std.meta.Child(std.meta.Child(@TypeOf(shape)));
    const names = @typeInfo(View).@"struct".field_names;
    const first = list(@FieldType(View, names[0]), columns.*[0]);

    if (first.items.len > limit or additional > limit - first.items.len) return error.OutOfMemory;

    const count = std.math.cast(usize, additional) orelse return error.OutOfMemory;

    inline for (names, 0..) |name, index| {
        try list(@FieldType(View, name), columns.*[index]).ensureUnusedCapacity(allocator, count);
    }
}

pub fn read(source: *const anyopaque, buffer: *const anyopaque, shape: anytype) std.meta.Child(@TypeOf(shape)) {
    const columns: *const ColumnSet = @ptrCast(@alignCast(source));
    const View = std.meta.Child(std.meta.Child(@TypeOf(shape)));
    const output: *View = @ptrCast(@alignCast(@constCast(buffer)));

    inline for (@typeInfo(View).@"struct".field_names, 0..) |name, index| {
        @field(output, name) = list(std.meta.Elem(@FieldType(View, name)), columns.*[index]).items;
    }

    return output;
}

pub fn append(target: *const anyopaque, row: anytype) void {
    const columns: *const ColumnSet = @ptrCast(@alignCast(target));
    const View = std.meta.Child(@TypeOf(row));

    inline for (@typeInfo(View).@"struct".field_names, 0..) |name, index| {
        list(@FieldType(View, name), columns.*[index]).appendAssumeCapacity(@field(row, name));
    }
}

pub fn appendProjection(target: *const anyopaque, source: anytype, shape: anytype) void {
    const columns: *const ColumnSet = @ptrCast(@alignCast(target));
    const Layout = std.meta.Child(std.meta.Child(@TypeOf(shape)));
    const optional = @typeInfo(@TypeOf(source)) == .optional;
    const Row = std.meta.Child(if (optional) std.meta.Child(@TypeOf(source)) else @TypeOf(source));
    const row: *const Row = if (optional) source orelse &std.mem.zeroes(Row) else source;

    inline for (@typeInfo(Row).@"struct".field_names) |name| {
        const index = comptime std.meta.fieldIndex(Layout, name).?;

        list(@FieldType(Layout, name), columns.*[index]).appendAssumeCapacity(@field(row, name));
    }
}

pub fn writeTail(target: *const anyopaque, row: anytype, index: u64) void {
    const columns: *const ColumnSet = @ptrCast(@alignCast(target));
    const View = std.meta.Child(@TypeOf(row));
    const offset: usize = @intCast(index);

    inline for (@typeInfo(View).@"struct".field_names, 0..) |name, slot| {
        list(@FieldType(View, name), columns.*[slot]).unusedCapacitySlice()[offset] = @field(row, name);
    }
}

pub fn writeSignatureTail(
    target: *const anyopaque,
    index: u64,
    files: []const u8,
    input_types: u32,
    output_types: u32,
    ownership: anytype,
    native_modules: ?u32,
    native_members: []const []const u8,
    native_exports: ?[]const u8,
    native_inputs: ?[]const ?[]const u8,
    native_errors: ?[]const []const u8,
    native_allocators: bool,
    native_io: bool,
    native_process: bool,
    native_tuples: bool,
    native_fallible: bool,
    native_concurrent: bool,
) void {
    // The column set follows the generated signature field order.
    const row = .{
        .files = files,
        .input_types = input_types,
        .native_allocators = native_allocators,
        .native_concurrent = native_concurrent,
        .native_errors = native_errors,
        .native_exports = native_exports,
        .native_fallible = native_fallible,
        .native_inputs = native_inputs,
        .native_io = native_io,
        .native_members = native_members,
        .native_modules = native_modules,
        .native_process = native_process,
        .native_tuples = native_tuples,
        .output_types = output_types,
        .ownership = ownership,
    };

    writeTail(target, &row, index);
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
