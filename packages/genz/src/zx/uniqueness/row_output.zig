const std = @import("std");
const memory = @import("zx").memory;
const Growth = @import("growth.zig");
const Level = @import("level.zig").Level;
const Memo = @import("memo.zig");
const copyRows = @import("retain.zig").copyRows;
const Function = @import("function.zig");

pub const ContributionRows = struct {
    callees: memory.ReadColumn,
    levels: memory.ListColumn,
    pub fn init(values: []const Function.Contribution) ContributionRows {
        return .{
            .callees = memory.borrowReadColumn(u32, "callee", values),
            .levels = memory.borrowSliceColumn(&.{"levels"}, values),
        };
    }

    pub fn view(self: *const ContributionRows, comptime View: type) View {
        return .{ .callees = @ptrCast(&self.callees), .levels = @ptrCast(&self.levels), .count = self.callees.count };
    }
};

pub fn Target(comptime Input: type, comptime field: []const u8) type {
    const Field = @FieldType(Input, field);

    return std.meta.Child(if (@typeInfo(Field) == .optional) @typeInfo(Field).optional.child else Field);
}

pub fn settlement(owner: std.mem.Allocator, value: anytype) std.mem.Allocator.Error!Memo.Settled {
    const passed = try owner.alloc(Function.Contribution, value.passed.len);
    var initialized: usize = 0;

    errdefer {
        for (passed[0..initialized]) |row| owner.free(row.levels);

        owner.free(passed);
    }

    for (passed, value.passed) |*row, source| {
        row.* = .{
            .callee = source.callee,
            .levels = try owner.dupe(Level, @ptrCast(source.guarantees)),
        };

        initialized += 1;
    }

    return .{ .passed = passed, .output = try owner.dupe(Level, @ptrCast(value.levels)) };
}

pub fn marks(owner: std.mem.Allocator, values: anytype) std.mem.Allocator.Error![]const Function.Mark {
    const result = try owner.alloc(Function.Mark, values.len);

    for (result, values) |*row, value| {
        row.* = .{
            .output = value.output,
            .function = value.function_index,
            .slot = value.slot,
            .want = @bitCast(@as(u3, @intCast(value.want))),
        };
    }

    return result;
}

pub fn reads(owner: std.mem.Allocator, values: anytype) std.mem.Allocator.Error![]const Function.Read {
    const result = try owner.alloc(Function.Read, values.len);

    for (result, values) |*row, value| {
        row.* = .{
            .table = @fromBackingInt(@intCast(value.table)),
            .function = value.function_index,
            .slot = value.slot,
            .value = @bitCast(@as(u3, @intCast(value.value))),
        };
    }

    return result;
}

pub fn growth(owner: std.mem.Allocator, snapshot: anytype) std.mem.Allocator.Error!Growth.Rows {
    const normalized = try growthRows(Growth.Normalized, owner, snapshot.normalized);

    errdefer owner.free(normalized);

    return .{
        .normalized = normalized,
        .renewed = try growthRows(Growth.Renewed, owner, snapshot.renewed),
    };
}

fn growthRows(comptime Row: type, owner: std.mem.Allocator, snapshot: anytype) std.mem.Allocator.Error![]const Row {
    if (snapshot.stored) |raw| return copyRows(Row, owner, raw);

    const rows = try owner.alloc(Row, snapshot.items.len);

    for (rows, snapshot.items) |*row, value| {
        const want: Level = @bitCast(@as(u3, @intCast(value.want)));

        row.* = if (Row == Growth.Normalized)
            .{ .id = @fromBackingInt(@as(u32, @intCast(value.key))), .want = want }

        else
            .{ .key = value.key, .want = want };
    }

    return rows;
}
