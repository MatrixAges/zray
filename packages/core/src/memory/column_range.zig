const std = @import("std");
const column_set = @import("column_set.zig");
const Error = std.mem.Allocator.Error;

pub const Range = struct {
    storage: *std.ArrayList(u8),
    tail: *anyopaque,
    count: usize,
    reserve: *const fn (*const Range, std.mem.Allocator, usize, bool) Error!void,
};

pub const Ranges = []const Range;

pub fn bind(storage: anytype, source: anytype, views: anytype) [@typeInfo(std.meta.Child(@TypeOf(storage))).@"struct".field_names.len]Range {
    const names = @typeInfo(std.meta.Child(@TypeOf(storage))).@"struct".field_names;
    var ranges: [names.len]Range = undefined;

    inline for (names, &ranges) |name, *range| {
        const column = &@field(storage, name);
        const Item = std.meta.Elem(@TypeOf(column.items));
        const tail_view: *[]const Item = &@field(views, name);
        const rows = @field(source, name);

        const Typed = struct {
            fn reserve(slot: *const Range, allocator: std.mem.Allocator, additional: usize, precise: bool) Error!void {
                const typed: *std.ArrayList(Item) = @ptrCast(@alignCast(slot.storage));
                const tail: *[]const Item = @ptrCast(@alignCast(slot.tail));

                if (precise) {
                    try typed.ensureTotalCapacityPrecise(allocator, typed.items.len + additional);
                } else {
                    try typed.ensureUnusedCapacity(allocator, additional);
                }

                tail.* = typed.unusedCapacitySlice()[0..slot.count];
            }
        };

        range.* = .{
            .storage = column_set.erase(column),
            .tail = @ptrCast(tail_view),
            .count = if (@typeInfo(@TypeOf(rows)) == .pointer) rows.len else rows,
            .reserve = Typed.reserve,
        };
    }

    return ranges;
}

fn view(target: *const anyopaque) Ranges {
    const ranges: *const Ranges = @ptrCast(@alignCast(target));

    return ranges.*;
}

pub inline fn columns(target: *const anyopaque) u64 {
    return view(target).len;
}

pub inline fn length(target: *const anyopaque, index: u64) u64 {
    return view(target)[@intCast(index)].storage.items.len;
}

pub inline fn count(target: *const anyopaque, index: u64) u64 {
    return view(target)[@intCast(index)].count;
}

pub inline fn setCount(target: *const anyopaque, index: u64, value: u64) void {
    @constCast(view(target))[@intCast(index)].count = @intCast(value);
}

pub fn reserveOne(resource: *const anyopaque, target: *const anyopaque, index: u64, uniform: ?u64, precise: bool) Error!void {
    const range = &view(target)[@intCast(index)];
    const additional = if (uniform) |value| @as(usize, @intCast(value)) else range.count;

    try range.reserve(range, column_set.borrowAllocator(resource), additional, precise);
}

pub inline fn publishOne(target: *const anyopaque, index: u64) void {
    const range = &view(target)[@intCast(index)];
    const storage = range.storage;

    std.debug.assert(range.count <= storage.capacity - storage.items.len);

    storage.items.len += range.count;
}
