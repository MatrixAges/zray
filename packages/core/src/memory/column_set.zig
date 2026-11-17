const std = @import("std");
pub const ColumnSet = []const *anyopaque;

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

pub fn reserve(resource: *const anyopaque, target: *const anyopaque, shape: anytype, limit: u64) std.mem.Allocator.Error!void {
    const allocator = borrowAllocator(resource);
    const columns: *const ColumnSet = @ptrCast(@alignCast(target));
    const View = std.meta.Child(std.meta.Child(@TypeOf(shape)));
    const names = @typeInfo(View).@"struct".field_names;
    const first = list(@FieldType(View, names[0]), columns.*[0]);

    if (first.items.len >= limit) return error.OutOfMemory;

    inline for (names, 0..) |name, index| {
        try list(@FieldType(View, name), columns.*[index]).ensureUnusedCapacity(allocator, 1);
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

fn list(comptime Item: type, storage: *anyopaque) *std.ArrayList(Item) {
    return @ptrCast(@alignCast(storage));
}

pub fn copyText(resource: *const anyopaque, source: []const u8) std.mem.Allocator.Error![]const u8 {
    return borrowAllocator(resource).dupe(u8, source);
}

pub fn copyTexts(resource: *const anyopaque, source: anytype) std.mem.Allocator.Error!@TypeOf(source) {
    const allocator = borrowAllocator(resource);
    const Text = std.meta.Elem(@TypeOf(source));
    const optional = @typeInfo(Text) == .optional;
    const result = try allocator.alloc(Text, source.len);
    var written: usize = 0;

    errdefer {
        for (result[0..written]) |item| {
            if (optional) {
                if (item) |text| allocator.free(text);
            } else allocator.free(item);
        }

        allocator.free(result);
    }

    for (source, result) |item, *target| {
        target.* = if (optional) (if (item) |text| try allocator.dupe(u8, text) else null) else try allocator.dupe(u8, item);
        written += 1;
    }

    return result;
}

fn borrowAllocator(resource: *const anyopaque) std.mem.Allocator {
    const allocator: *const std.mem.Allocator = @ptrCast(@alignCast(resource));

    return allocator.*;
}
