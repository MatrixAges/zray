const std = @import("std");
const zx = @import("zx");
pub const available = @import("parser_options").generated_parser;
pub const manifest_read = if (available) @import("generated_output_manifest_read") else null;
pub const manifest_write = if (available) @import("generated_output_manifest_write") else null;
pub const inventory = @import("output/inventory.zig");
pub const assembly = @import("output/assembly.zig");
pub const tree = @import("output/tree.zig");

pub const Input = struct {
    paths: []const []const u8,
    hashes: []const u64,
    previous_paths: []const []const u8,
    previous_hashes: []const u64,
    present: bool,
};

pub const Selection = struct { changed: []const u32, aligned: bool };

pub const Changes = struct {
    arena: std.heap.ArenaAllocator,
    value: Selection,
    pub fn deinit(self: *@This()) void {
        self.arena.deinit();

        self.* = undefined;
    }
};

pub fn changes(workspace: std.mem.Allocator, input: Input) std.mem.Allocator.Error!Changes {
    var arena = std.heap.ArenaAllocator.init(workspace);

    errdefer arena.deinit();

    const allocator = arena.allocator();

    if (comptime !available) return .{ .arena = arena, .value = try @import("output_seed.zig").changes(allocator, input) };

    const entry = @import("generated_output_changes");
    const Fields = std.meta.Child(entry.Input);
    var index_values: []u32 = &.{};
    var index_buckets: []?u32 = &.{};

    const fields: Fields = .{
        .paths = input.paths,
        .hashes = input.hashes,
        .previous_paths = input.previous_paths,
        .previous_hashes = input.previous_hashes,
        .present = input.present,
        .index_values = @ptrCast(&index_values),
        .index_buckets = @ptrCast(&index_buckets),
    };

    const result = zx.columns.invoke(entry.executeValue, allocator, &fields) catch |err| return failure(err);

    return .{ .arena = arena, .value = .{ .changed = result.changed, .aligned = result.aligned } };
}

fn failure(err: anyerror) std.mem.Allocator.Error {
    return switch (err) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => error.OutOfMemory,
        else => @panic("invalid generated file ledger"),
    };
}
