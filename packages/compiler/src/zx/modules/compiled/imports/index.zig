const std = @import("std");
const zx = @import("zx");
const Export = @import("../../compiled.zig").Export;
const Names = @import("../../source_index.zig").Map;
const generated = @import("parser_options").generated_parser;
const Self = @This();

storage: if (generated) []u64 else Names = if (generated) &.{} else .empty,
pub fn init(allocator: std.mem.Allocator, count: usize) std.mem.Allocator.Error!Self {
    const size = if (count > 1) count else 0;

    return .{ .storage = if (comptime generated) try Names.bucketsFor(allocator, size) else try Names.init(allocator, size) };
}

pub fn deinit(self: Self, allocator: std.mem.Allocator) void {
    if (comptime generated) allocator.free(self.storage) else self.storage.deinit(allocator);
}

pub fn buckets(self: Self) ?[]u64 {
    return if (generated) self.storage else null;
}

pub fn finish(self: *Self, exports: []const Export) error{InvalidLibrary}!void {
    if (comptime !generated) {
        if (exports.len < 2) return;

        for (exports, 0..) |*exported, row| {
            if (!self.storage.claim(row, exported.name)) return error.InvalidLibrary;
        }
    }
}

pub fn find(self: *const Self, exports: []const Export, name: []const u8) ?usize {
    if (comptime generated) {
        const rule = @import("generated_compiled_import_find");
        const Input = std.meta.Child(rule.Input);
        const names = zx.memory.borrowTextColumn("name", exports);
        const values: []u64 = self.storage;

        const input: Input = .{
            .names = @ptrCast(&names),
            .buckets = @ptrCast(&values),
            .capacity = values.len,
            .count = exports.len,
            .name = name,
        };

        var scratch = std.heap.FixedBufferAllocator.init(&.{});
        const row = zx.columns.invoke(rule.executeValue, scratch.allocator(), &input) catch unreachable;

        return if (row) |index| @intCast(index) else null;
    }

    if (exports.len == 1) return if (zx.bytes.equal(exports[0].name, name)) 0 else null;

    return self.storage.get(name);
}
