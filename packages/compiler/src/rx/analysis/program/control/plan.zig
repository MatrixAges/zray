const std = @import("std");
const zx = @import("zx");
const Shape = @import("../flow.zig");
const Error = @import("../builder.zig").Error;
const enabled = @import("rx_options").generated_graph;
const Self = @This();

// The packed planning rows use the lane order in const.zx.
pub const Counts = extern struct {
    evaluations: u32 = 0,
    constants: u32 = 0,
    parallels: u32 = 0,
    invocations: u32 = 0,
    selections: u32 = 0,
    cases: u32 = 0,
    results: u32 = 0,
    pub fn statements(self: Counts) u64 {
        return @as(u64, self.evaluations) + self.constants + self.parallels + self.selections + self.results;
    }
    pub fn plus(self: Counts, other: Counts) std.mem.Allocator.Error!Counts {
        var result: Counts = undefined;

        inline for (@typeInfo(Counts).@"struct".field_names) |name| {
            @field(result, name) = std.math.add(u32, @field(self, name), @field(other, name)) catch return error.OutOfMemory;
        }

        return result;
    }
};

pub const Row = extern struct {
    first: Counts,
    tag: u32,
};

pub const Blocks = struct { firsts: []u32, counts: []u32 };

rows: []const Row,
blocks: []const bool,
size: Counts,
implicit_return: bool,
pub fn make(allocator: std.mem.Allocator, shape: *const Shape, blocks: Blocks, capture_count: usize, void_output: bool) Error!Self {
    const rows = try allocator.alloc(Row, shape.units.len);

    if (comptime !enabled) return @import("seed.zig").plan(shape, rows, blocks, capture_count, void_output);

    const rule = @import("generated_rx_control_layout");
    const Parameter = rule.Input;
    const Input = if (comptime @typeInfo(Parameter) == .pointer) std.meta.Child(Parameter) else Parameter;
    const Columns = std.meta.Child(@FieldType(Input, "shape"));
    const Steps = std.meta.Child(@FieldType(Columns, "steps"));
    var scratch_bytes: [4096]u8 = undefined;
    var fallback = std.heap.BufferFirstAllocator.init(&scratch_bytes, allocator);
    var arena = std.heap.ArenaAllocator.init(fallback.allocator());

    defer arena.deinit();

    const input: Input = .{
        .shape = &.{
            .steps = &.{
                .kinds = zx.columns.slice(@FieldType(Steps, "kinds"), @as([]const Shape.Kind, shape.steps.items(.kind))),
                .outputs = zx.columns.slice(@FieldType(Steps, "outputs"), @as([]const Shape.Publish, shape.steps.items(.output))),
                .firsts = shape.steps.items(.first),
                .counts = shape.steps.items(.count),
                .exhaustive = shape.steps.items(.exhaustive),
            },
            .units = &.{ .firsts = shape.units.items(.first), .counts = shape.units.items(.count), .blocks = shape.units.items(.block) },
            .cases = shape.cases.items(.body),
            .calls = &.{ .getters = shape.calls.items(.getters), .publishes = shape.calls.items(.publishes) },
        },
        .capture_count = capture_count,
        .void_output = void_output,
    };

    const result = rule.executeValue(arena.allocator(), if (comptime @typeInfo(Parameter) == .pointer) &input else input) catch |err| switch (@as(anyerror, err)) {
        error.IndexOutOfBounds => return error.InvalidModule,
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => return error.OutOfMemory,
        else => unreachable,
    };

    switch (result.status) {
        .Ready => {},
        .Unreachable => return error.UnreachableFlow,
        .Incomplete => return error.IncompleteFlow,
    }

    var size: Counts = undefined;

    inline for (@typeInfo(Counts).@"struct".field_names) |name| {
        @field(size, name) = std.math.cast(u32, @field(result, name)) orelse return error.OutOfMemory;
    }

    if (size.statements() > std.math.maxInt(u32)) return error.OutOfMemory;

    for (result.rows, 0..) |row, index| {
        rows[index] = .{
            .first = .{
                .evaluations = row.evaluations,
                .constants = row.constants,
                .parallels = row.parallels,
                .invocations = row.invocations,
                .selections = row.selections,
                .cases = row.cases,
                .results = row.results,
            },
            .tag = row.tag,
        };
    }

    @memcpy(blocks.firsts[0..result.block_firsts.len], result.block_firsts);
    @memcpy(blocks.counts[0..result.block_counts.len], result.block_counts);

    return .{ .rows = rows, .blocks = shape.units.items(.block), .size = size, .implicit_return = result.implicit_return };
}

pub fn root(self: Self) u32 {
    return @intCast(self.rows.len - 1);
}

pub fn end(self: *const Self, unit: u32) *const Counts {
    const next = @as(usize, unit) + 1;

    if (next == self.rows.len) return &self.size;

    // Placement records the successor on the first row of each run of inline units.
    const successor = if (self.blocks[next]) next else self.rows[next].tag;

    return &self.rows[successor].first;
}
