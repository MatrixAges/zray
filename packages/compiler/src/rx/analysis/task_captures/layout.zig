const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Expressions = @import("frontend").expressions;
const enabled = @import("rx_options").generated_graph;
const Self = @This();

positions: []const u32 = &.{},
source_types: []const ir.TypeId = &.{},
parameter_types: []const ir.TypeId = &.{},
elements: []const ir.ExprId = &.{},
optional_count: usize = 0,
pub fn admits(types: ir.TypeTable, children: []const ir.TypeId) bool {
    if (children.len == 0) return true;

    if (comptime !enabled) {
        for (children) |id| {
            if (types.at(@backingInt(id)) == .task) return false;
        }

        return true;
    }

    const rule = @import("generated_rx_task_capture_admission");
    const Input = std.meta.Child(rule.Input);
    const Tables = std.meta.Child(@FieldType(Input, "tables"));
    const Table = std.meta.Child(@FieldType(Tables, "base"));
    const base = ir.TypeTable.borrow(Table, types);
    const delta = ir.TypeTable.borrow(Table, .{});

    const input: Input = .{
        .tables = &.{ .base = &base, .delta = &delta },
        .candidate = &.{ .kind = .Tuple, .first = 0, .second = 0, .label = "", .children = @ptrCast(children), .fields = &.{ .names = &.{}, .types = &.{} }, .names = &.{} },
    };

    var empty = std.heap.FixedBufferAllocator.init(&.{});

    return (zx.columns.invoke(rule.executeValue, empty.allocator(), &input) catch unreachable) == .None;
}

pub fn plan(allocator: std.mem.Allocator, types: []const ir.TypeId, captures: @import("../task_captures.zig"), parameters: []const ir.TypeId) std.mem.Allocator.Error!Self {
    const count = types.len - captures.remaining;

    if (count == 0) return .{};
    if (count > (std.math.maxInt(u32) - 1) / 3) return error.OutOfMemory;

    if (comptime !enabled) {
        const positions = try captures.seedPositions(allocator);

        return @import("layout/seed.zig").plan(allocator, types, positions, parameters);
    }

    const rule = @import("generated_rx_task_capture_layout");

    const input: std.meta.Child(rule.Input) = .{
        .types = @ptrCast(types),
        .parameters = @ptrCast(parameters),
        .marked = captures.marked.items,
        .count = count,
    };

    const result = zx.columns.invoke(rule.executeValue, allocator, &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => return error.OutOfMemory,
        else => unreachable,
    };

    return .{
        .positions = result.positions,
        .source_types = @ptrCast(result.source_types),
        .parameter_types = @ptrCast(result.parameter_types),
        .optional_count = @intCast(result.optional_count),
    };
}

pub fn scope(allocator: std.mem.Allocator, types: ir.TypeTable, bindings: Expressions.BindingColumns, facts: []const []const u8) std.mem.Allocator.Error!Expressions.BindingStorage {
    var selected: Expressions.BindingStorage = .empty;

    try selected.resize(allocator, bindings.names.len);

    @memcpy(selected.items(.name), bindings.names);

    const selected_types = selected.items(.type_id);

    if (facts.len == 0 or bindings.names.len == 0) {
        @memcpy(selected_types, bindings.types);

        return selected;
    }

    if (comptime !enabled) {
        @import("layout/seed.zig").narrow(types, bindings, facts, selected_types);

        return selected;
    }

    const rule = @import("generated_rx_task_capture_narrow");
    const Input = std.meta.Child(rule.Input);
    var arena = std.heap.ArenaAllocator.init(allocator);

    defer arena.deinit();

    var buffer: [512]u8 = undefined;
    var scratch = std.heap.BufferFirstAllocator.init(&buffer, arena.allocator());

    const input: Input = .{
        .names = bindings.names,
        .types = @ptrCast(bindings.types),
        .kinds = types.kinds,
        .children = types.first,
        .facts = facts,
    };

    const narrowed = zx.columns.invoke(rule.executeValue, scratch.allocator(), &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };

    @memcpy(selected_types, @as([]const ir.TypeId, @ptrCast(narrowed)));

    return selected;
}
