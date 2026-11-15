const std = @import("std");
const ir = @import("../ir.zig");
const Table = @import("root.zig");
const Self = @This();

names: std.ArrayList([]const u8) = .empty,
types: std.ArrayList(u32) = .empty,
span_start: std.ArrayList(u64) = .empty,
span_end: std.ArrayList(u64) = .empty,
ownership: std.ArrayList(Table.Ownership) = .empty,
pub fn count(self: *const Self) usize {
    return self.names.items.len;
}

pub fn at(self: *const Self, index: usize) ir.Symbol {
    return self.view().at(index);
}

pub fn append(self: *Self, allocator: std.mem.Allocator, value: ir.Symbol) std.mem.Allocator.Error!void {
    if (self.count() == std.math.maxInt(u32)) return error.OutOfMemory;

    inline for (@typeInfo(Self).@"struct".field_names) |name| {
        try @field(self, name).ensureUnusedCapacity(allocator, 1);
    }

    self.names.appendAssumeCapacity(value.name);
    self.types.appendAssumeCapacity(@backingInt(value.type_id));
    self.span_start.appendAssumeCapacity(value.span.start);
    self.span_end.appendAssumeCapacity(value.span.end);

    self.ownership.appendAssumeCapacity(switch (value.ownership) {
        .copy => .Copy,
        .borrowed => .Borrowed,
        .owned => .Owned,
    });
}

/// Adds the source suffix as fresh symbols. Borrowed names must outlive the destination.
pub fn appendFresh(self: *Self, allocator: std.mem.Allocator, source: Table, first: usize, borrow_names: bool) std.mem.Allocator.Error!void {
    const length = source.count() - first;
    const base = self.count();

    if (length == 0) return;
    if (length > std.math.maxInt(u32) - base) return error.OutOfMemory;

    inline for (@typeInfo(Self).@"struct".field_names) |name| {
        try @field(self, name).ensureUnusedCapacity(allocator, length);
    }

    const names = self.names.unusedCapacitySlice()[0..length];

    if (borrow_names) {
        @memcpy(names, source.names[first..]);
    } else {
        var copied: usize = 0;

        errdefer for (names[0..copied]) |name| allocator.free(name);

        for (source.names[first..], names) |name, *target| {
            target.* = try allocator.dupe(u8, name);
            copied += 1;
        }
    }

    inline for (.{ "types", "span_start", "span_end" }) |name| {
        @memcpy(@field(self, name).unusedCapacitySlice()[0..length], @field(source, name)[first..]);
    }

    @memset(self.ownership.unusedCapacitySlice()[0..length], .Copy);

    inline for (@typeInfo(Self).@"struct".field_names) |name| {
        @field(self, name).items.len += length;
    }
}

pub fn view(self: *const Self) Table {
    var result: Table = .{};

    inline for (@typeInfo(Self).@"struct".field_names) |name| @field(result, name) = @field(self, name).items;

    return result;
}

pub fn finish(self: *Self, allocator: std.mem.Allocator) std.mem.Allocator.Error!Table {
    var result: Table = .{};

    const complete = collect: {
        inline for (@typeInfo(Self).@"struct".field_names) |name| {
            @field(result, name) = @field(self, name).toOwnedSlice(allocator) catch break :collect false;
        }

        break :collect true;
    };

    if (!complete) {
        inline for (@typeInfo(Table).@"struct".field_names) |name| allocator.free(@field(result, name));
        self.deinit(allocator);

        return error.OutOfMemory;
    }

    return result;
}

pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    inline for (@typeInfo(Self).@"struct".field_names) |name| @field(self, name).deinit(allocator);

    self.* = .{};
}
