const std = @import("std");
const zx = @import("zx");
pub const available = @import("parser_options").generated_parser;
const entry = if (available) @import("generated_partition_layout") else void;

pub const FunctionFiles = struct {
    paths: []const []const u8,
    names: []const []const u8,
    sizes: []const u64,
};

pub const Input = struct {
    paths: []const []const u8,
    sizes: []const u64,
    callees: []const []const u32,
    variants: []const []const []const u8,
    inline_names: []const []const []const u8,
    top_callees: []const []const u32,
    top_variants: []const []const []const u8,
    count: u32,
};

pub const Plan = if (available)
    @typeInfo(@typeInfo(@TypeOf(entry.executeValue)).@"fn".return_type.?).error_union.payload

else
    void;

pub const Owned = struct {
    arena: std.heap.ArenaAllocator,
    value: Plan,
    pub fn deinit(self: *@This()) void {
        self.arena.deinit();

        self.* = undefined;
    }
};

pub fn create(workspace: std.mem.Allocator, input: Input) std.mem.Allocator.Error!Owned {
    if (comptime !available) unreachable;

    var arena = std.heap.ArenaAllocator.init(workspace);

    errdefer arena.deinit();

    const allocator = arena.allocator();
    const Fields = std.meta.Child(entry.Input);

    const fields: Fields = .{
        .paths = input.paths,
        .sizes = input.sizes,
        .callees = input.callees,
        .variants = input.variants,
        .inline_names = input.inline_names,
        .top_callees = input.top_callees,
        .top_variants = input.top_variants,
        .count = input.count,
    };

    const output = zx.columns.invoke(entry.executeValue, allocator, &fields) catch |err| return failure(err);

    return .{ .arena = arena, .value = output };
}

fn failure(err: anyerror) std.mem.Allocator.Error {
    return switch (err) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => error.OutOfMemory,
        else => @panic("invalid partition layout input"),
    };
}
