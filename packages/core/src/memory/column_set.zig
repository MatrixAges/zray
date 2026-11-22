const std = @import("std");
pub const ColumnSet = []const *anyopaque;
pub const Lengths = []const *usize;

pub fn borrowLengths(storage: anytype) [@typeInfo(std.meta.Child(@TypeOf(storage))).@"struct".field_names.len]*usize {
    const fields = @typeInfo(std.meta.Child(@TypeOf(storage))).@"struct".field_names;
    var lengths: [fields.len]*usize = undefined;

    inline for (fields, &lengths) |name, *length| {
        length.* = &@field(storage, name).items.len;
    }

    return lengths;
}

pub fn publishLengths(target: *const anyopaque, count: u64) void {
    const lengths: *const Lengths = @ptrCast(@alignCast(target));
    const additional: usize = @intCast(count);

    for (lengths.*) |length| length.* += additional;
}

pub fn restoreLengths(target: *const anyopaque, counts: []const u64) void {
    const lengths: *const Lengths = @ptrCast(@alignCast(target));

    for (lengths.*, counts) |length, count| {
        std.debug.assert(count <= length.*);

        length.* = @intCast(count);
    }
}

pub fn captureLengths(source: *const anyopaque, target: *const anyopaque) void {
    const lengths: *const Lengths = @ptrCast(@alignCast(source));
    const counts: *const []u64 = @ptrCast(@alignCast(target));

    for (lengths.*, counts.*) |length, *count| count.* = length.*;
}

pub fn firstLength(source: *const anyopaque) u64 {
    const lengths: *const Lengths = @ptrCast(@alignCast(source));

    return lengths.*[0].*;
}

pub fn truncateLengths(target: *const anyopaque, count: u64) void {
    const lengths: *const Lengths = @ptrCast(@alignCast(target));
    const limit: usize = @intCast(count);

    for (lengths.*) |length| {
        std.debug.assert(limit <= length.*);

        length.* = limit;
    }
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

pub const Range = struct {
    storage: *anyopaque,
    view: *anyopaque,
    count: usize,
};

pub const Ranges = []const Range;

pub fn bindRanges(comptime Elements: type, storage: anytype, source: anytype, views: anytype) [@typeInfo(Elements).@"struct".field_types.len]Range {
    const names = @typeInfo(std.meta.Child(@TypeOf(storage))).@"struct".field_names;
    const items = @typeInfo(Elements).@"struct".field_types;
    var ranges: [items.len]Range = undefined;

    inline for (names, items, &ranges) |name, Item, *range| {
        const column: *std.ArrayList(Item) = &@field(storage, name);
        const view: *[]const Item = &@field(views, name);
        const rows = @field(source, name);

        range.* = .{
            .storage = column,
            .view = @ptrCast(view),
            .count = if (@typeInfo(@TypeOf(rows)) == .pointer) rows.len else rows,
        };
    }

    return ranges;
}

pub fn reserveRanges(resource: *const anyopaque, target: *const anyopaque, elements: anytype, limit: ?u64, precise: bool, comptime uniform: bool) std.mem.Allocator.Error!void {
    const columns: *const Ranges = @ptrCast(@alignCast(target));
    const items = comptime rangeElements(@TypeOf(elements));
    const allocator = borrowAllocator(resource);

    if (limit) |maximum| {
        inline for (items, 0..) |Item, index| {
            const current = list(Item, columns.*[index].storage).items.len;

            if (current > maximum or columns.*[index].count > maximum - current) return error.OutOfMemory;
        }
    }

    inline for (items, 0..) |Item, index| {
        const range = columns.*[index];
        const column = list(Item, range.storage);
        const count = if (uniform) columns.*[0].count else range.count;

        if (precise) {
            try column.ensureTotalCapacityPrecise(allocator, column.items.len + count);
        } else {
            try column.ensureUnusedCapacity(allocator, count);
        }

        const view: *[]const Item = @ptrCast(@alignCast(range.view));
        view.* = column.unusedCapacitySlice()[0..range.count];
    }
}

pub fn publishRanges(target: *const anyopaque, elements: anytype) void {
    const columns: *const Ranges = @ptrCast(@alignCast(target));
    const items = comptime rangeElements(@TypeOf(elements));

    inline for (items, 0..) |Item, index| {
        const range = columns.*[index];
        _ = list(Item, range.storage).addManyAsSliceAssumeCapacity(range.count);
    }
}

pub inline fn setRangeCount(target: *const anyopaque, index: u64, count: u64) void {
    const columns: *const Ranges = @ptrCast(@alignCast(target));

    @constCast(columns.*)[@intCast(index)].count = @intCast(count);
}

fn rangeElements(comptime Shape: type) []const type {
    const Elements = std.meta.Child(@typeInfo(Shape).optional.child);

    return @typeInfo(Elements).@"struct".field_types;
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

pub fn borrowAllocator(resource: *const anyopaque) std.mem.Allocator {
    const allocator: *const std.mem.Allocator = @ptrCast(@alignCast(resource));

    return allocator.*;
}
