const std = @import("std");
const zx = @import("zx");
const Graph = @import("../inference/types.zig");
const Scope = @import("../inference/scope.zig");
const Typed = @import("frontend").expressions.BindingStorage;
const Binding = @import("../store.zig").Binding;
const generated = @import("rx_options").generated_graph;

pub const Columns = struct {
    names: zx.memory.TextColumn,
    types: zx.memory.ReadColumn,
    count: usize,
    pub fn init(getters: []const Binding) Columns {
        return .{
            .names = zx.memory.borrowTextColumn("name", getters),
            .types = zx.memory.borrowReadColumn(zx.ir.TypeId, "type_id", getters),
            .count = getters.len,
        };
    }

    pub fn view(self: *const Columns, comptime Target: type) Target {
        return .{ .names = @ptrCast(&self.names), .types = @ptrCast(&self.types), .count = self.count };
    }
};

pub fn infer(graph: *Graph, scope: *Scope.Storage, allocator: std.mem.Allocator, getters: []const Binding, span: zx.Span) zx.Error!void {
    if (getters.len == 0) return;

    if (comptime !generated) {
        for (getters) |getter| {
            try scope.append(allocator, .{ .name = getter.name, .value = try graph.known(getter.type_id, span) });
        }

        return;
    }

    const first = scope.len;

    try scope.ensureUnusedCapacity(allocator, getters.len);

    var rows = scope.slice();

    rows.len = first + getters.len;

    const names = rows.items(.name)[first..];
    const values: []u32 = @ptrCast(rows.items(.value)[first..]);
    const spans = rows.items(.span)[first..];
    const columns = Columns.init(getters);
    var next: usize = 0;

    while (next < getters.len) {
        const end = try write(allocator, &columns, graph, next, names, values);

        @memset(spans[next..end], .{ .start = 0, .end = 0 });

        scope.len = first + end;

        if (end == getters.len) return;
        try @import("../inference/known.zig").registerMembers(graph, &.{@backingInt(getters[end].type_id)}, span);

        next = end;
    }
}

pub fn typed(scope: *Typed, allocator: std.mem.Allocator, getters: []const Binding) std.mem.Allocator.Error!void {
    if (getters.len == 0) return;

    if (comptime !generated) {
        for (getters) |getter| try scope.append(allocator, .{ .name = getter.name, .type_id = getter.type_id });

        return;
    }

    const first = scope.len;

    try scope.ensureUnusedCapacity(allocator, getters.len);

    var rows = scope.slice();

    rows.len = first + getters.len;

    const written = try write(allocator, &Columns.init(getters), null, 0, rows.items(.name)[first..], @ptrCast(rows.items(.type_id)[first..]));

    std.debug.assert(written == getters.len);

    scope.len = rows.len;
}

fn write(allocator: std.mem.Allocator, columns: *const Columns, graph: ?*Graph, first: usize, names: [][]const u8, values: []u32) std.mem.Allocator.Error!usize {
    var buffer: [1024]u8 align(@alignOf(u64)) = undefined;
    var backing = std.heap.BufferFirstAllocator.init(&buffer, allocator);
    var arena = std.heap.ArenaAllocator.init(backing.allocator());

    defer arena.deinit();

    const rule = @import("generated_rx_store_scope_bindings");
    const Input = std.meta.Child(rule.Input);
    const Known = std.meta.Child(@typeInfo(@FieldType(Input, "known")).optional.child);
    const known = if (graph) |g| g.pending.known_types.borrow(Known) else undefined;

    const input: Input = .{
        .getters = &columns.view(std.meta.Child(@FieldType(Input, "getters"))),
        .known = if (graph != null) &known else null,
        .first = first,
    };

    const result = zx.columns.invoke(rule.executeValue, arena.allocator(), &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => return error.OutOfMemory,
        else => unreachable,
    };

    for (result.rows, 0..) |row, offset| {
        names[first + offset] = row.name;
        values[first + offset] = row.value;
    }

    return @intCast(result.next);
}
