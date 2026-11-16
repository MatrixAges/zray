const std = @import("std");
const ir = @import("zx").ir;
const Level = @import("level.zig").Level;
const generated = @import("genz_options").generated_analysis;
pub const Normalized = struct { id: ir.ExprId, want: Level };
pub const Renewed = struct { key: u64, want: Level };

pub const Rows = struct {
    normalized: []const Normalized = &.{},
    renewed: []const Renewed = &.{},
    pub fn copy(self: Rows, allocator: std.mem.Allocator) std.mem.Allocator.Error!Rows {
        const normalized = try allocator.dupe(Normalized, self.normalized);

        errdefer allocator.free(normalized);

        return .{ .normalized = normalized, .renewed = try allocator.dupe(Renewed, self.renewed) };
    }
};

pub const Store = if (generated) Rows else Seed;

pub fn init(allocator: std.mem.Allocator) Store {
    return if (generated) .{} else .{ .normalized = .init(allocator), .renewed = .init(allocator) };
}

pub fn clear(store: *Store) void {
    if (generated) {
        store.* = .{};
    } else {
        store.normalized.clearRetainingCapacity();
        store.renewed.clearRetainingCapacity();
    }
}

pub fn restore(store: *Store, rows: Rows) std.mem.Allocator.Error!void {
    if (generated) {
        store.* = rows;
    } else {
        clear(store);

        for (rows.normalized) |entry| try store.normalized.put(entry.id, entry.want);
        for (rows.renewed) |entry| try store.renewed.put(entry.key, entry.want);
    }
}

const Seed = struct {
    normalized: std.AutoHashMap(ir.ExprId, Level),
    renewed: std.AutoHashMap(u64, Level),
    pub fn clone(self: *const Seed, allocator: std.mem.Allocator) std.mem.Allocator.Error!Seed {
        var normalized = try self.normalized.cloneWithAllocator(allocator);

        errdefer normalized.deinit();

        return .{ .normalized = normalized, .renewed = try self.renewed.cloneWithAllocator(allocator) };
    }
    pub fn capture(self: *const Seed, allocator: std.mem.Allocator) std.mem.Allocator.Error!Rows {
        const normalized = try allocator.alloc(Normalized, self.normalized.count());

        errdefer allocator.free(normalized);

        const renewed = try allocator.alloc(Renewed, self.renewed.count());
        var copies = self.normalized.iterator();
        var renewals = self.renewed.iterator();

        for (normalized) |*target| {
            const entry = copies.next().?;

            target.* = .{ .id = entry.key_ptr.*, .want = entry.value_ptr.* };
        }

        for (renewed) |*target| {
            const entry = renewals.next().?;

            target.* = .{ .key = entry.key_ptr.*, .want = entry.value_ptr.* };
        }

        return .{ .normalized = normalized, .renewed = renewed };
    }
};
