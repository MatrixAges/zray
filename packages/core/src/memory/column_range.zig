const std = @import("std");
const column_set = @import("column_set.zig");
const Error = std.mem.Allocator.Error;

pub const Range = struct {
    storage: *std.ArrayList(u8),
    tail: *anyopaque,
    count: usize,
    reserve: *const fn (*const Range, std.mem.Allocator, usize, bool) bool,
};

pub const Ranges = []Range;

fn bindOne(column: anytype, size: usize, tail_view: *anyopaque, comptime bytes: bool) Range {
    const Item = std.meta.Elem(@TypeOf(column.items));
    const View = if (bytes) u8 else Item;

    const Typed = struct {
        fn reserve(slot: *const Range, allocator: std.mem.Allocator, additional: usize, precise: bool) bool {
            const typed: *std.ArrayList(Item) = @ptrCast(@alignCast(slot.storage));
            const tail: *[]const View = @ptrCast(@alignCast(slot.tail));

            if (precise) {
                typed.ensureTotalCapacityPrecise(allocator, typed.items.len + additional) catch return false;
            } else {
                typed.ensureUnusedCapacity(allocator, additional) catch return false;
            }

            const items = typed.unusedCapacitySlice()[0..slot.count];

            tail.* = if (bytes) std.mem.sliceAsBytes(items) else items;

            return true;
        }
    };

    return .{ .storage = column_set.erase(column), .tail = tail_view, .count = size, .reserve = Typed.reserve };
}

fn view(target: *const anyopaque) Ranges {
    const ranges: *const Ranges = @ptrCast(@alignCast(target));

    return ranges.*;
}

fn viewMut(target: *anyopaque) Ranges {
    const ranges: *Ranges = @ptrCast(@alignCast(target));

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

pub fn reserveOne(resource: *const anyopaque, target: *anyopaque, index: u64, uniform: ?u64, precise: bool) Error!void {
    const range = &viewMut(target)[@intCast(index)];
    const additional = if (uniform) |value| @as(usize, @intCast(value)) else range.count;

    if (!range.reserve(range, column_set.borrowAllocator(resource), additional, precise)) return error.OutOfMemory;
}

pub fn Group(comptime capacity: usize) type {
    return struct {
        const Self = @This();

        descriptors: [capacity]Range = undefined,
        tails: [capacity][]const u8 = undefined,
        active: Ranges = undefined,
        len: usize = 0,
        pub fn bind(self: *Self, column: anytype, additional: usize, comptime bytes: bool) *anyopaque {
            const index = self.len;
            const tail = &self.tails[index];
            self.descriptors[index] = bindOne(column, additional, @ptrCast(tail), bytes);
            self.len = index + 1;

            return @ptrCast(tail);
        }

        pub fn freeze(self: *Self) ?*Ranges {
            if (self.len == 0) return null;

            self.active = self.descriptors[0..self.len];

            return &self.active;
        }
    };
}
