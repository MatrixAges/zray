const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Plan = @import("plan.zig");
const Counts = Plan.Counts;
const Kind = std.meta.Child(@FieldType(ir.ControlTable, "statement_kinds"));
const Error = @import("../builder.zig").Error;
const Self = @This();

pub const Cursor = extern struct {
    counts: Counts,
    statement: u32,
    pub fn init(first: Counts) Cursor {
        return .{ .counts = first, .statement = @intCast(first.statements()) };
    }
    pub fn cells(self: *Cursor) []u32 {
        return @as(*[@sizeOf(Cursor) / @sizeOf(u32)]u32, @ptrCast(self));
    }
};

columns: ir.ControlStorage = .{},
pub fn finishBlock(_: *const Self, cursor: *const Cursor, block: u32, end: *const Counts) Error!ir.BlockId {
    if (!std.meta.eql(cursor.counts, end.*) or cursor.statement != end.statements()) {
        return error.InvalidModule;
    }

    return @fromBackingInt(block);
}

pub fn init(allocator: std.mem.Allocator, blocks: u32) std.mem.Allocator.Error!Self {
    var writer: Self = .{};

    errdefer writer.columns.deinit(allocator);

    try writer.allocate(allocator, &.{ "block_first", "block_count" }, blocks);

    return writer;
}

pub fn reserve(self: *Self, allocator: std.mem.Allocator, size: Counts) std.mem.Allocator.Error!void {
    try self.allocate(allocator, &.{ "statement_kinds", "statement_payloads" }, @intCast(size.statements()));
    try self.allocate(allocator, &.{"evaluations"}, size.evaluations);
    try self.allocate(allocator, &.{ "constant_symbols", "constant_values" }, size.constants);
    try self.allocate(allocator, &.{ "parallel_first", "parallel_count" }, size.parallels);
    try self.allocate(allocator, &.{ "parallel_symbols", "parallel_values" }, size.invocations);
    try self.allocate(allocator, &.{ "selection_subjects", "selection_first", "selection_count", "selection_exhaustive" }, size.selections);
    try self.allocate(allocator, &.{ "case_values", "case_bodies" }, size.cases);
    try self.allocate(allocator, &.{"results"}, size.results);
}

pub fn evaluate(self: *Self, cursor: *Cursor, value: ir.ExprId) void {
    self.binding(cursor, .Evaluate, &self.columns.evaluations.items, null, 0, @backingInt(value));
}

pub fn constant(self: *Self, cursor: *Cursor, symbol: ir.SymbolId, value: ir.ExprId) void {
    self.binding(cursor, .Constant, &self.columns.constant_values.items, &self.columns.constant_symbols.items, @backingInt(symbol), @backingInt(value));
}

fn binding(self: *Self, cursor: *Cursor, comptime kind: Kind, values: *const []u32, symbols: ?*const []u32, symbol: u32, value: u32) void {
    const row = if (kind == .Constant) &cursor.counts.constants else &cursor.counts.evaluations;

    values.*[row.*] = value;

    if (symbols) |output| output.*[row.*] = symbol;

    self.seedHeader(cursor.statement, kind, row.*);

    row.* += 1;
    cursor.statement += 1;
}

pub fn result(self: *Self, cursor: *Cursor, value: ?ir.ExprId) void {
    const id = if (value) |item| @backingInt(item) else null;
    const row = cursor.counts.results;

    self.columns.results.items[row] = id;

    self.seedHeader(cursor.statement, .Result, row);

    cursor.counts.results += 1;
    cursor.statement += 1;
}

pub fn parallelBranch(self: *Self, position: usize, symbol: ?ir.SymbolId, value: ir.ExprId) void {
    member(position, &self.columns.parallel_symbols.items, &self.columns.parallel_values.items, if (symbol) |id| @backingInt(id) else null, @backingInt(value));
}

pub fn parallel(self: *Self, cursor: *Cursor, count: usize, bindings: []ir.SymbolId) void {
    const symbols = self.columns.parallel_symbols.items[cursor.counts.invocations..][0..count];
    const row = cursor.counts.parallels;

    self.columns.parallel_first.items[row] = cursor.counts.invocations;
    self.columns.parallel_count.items[row] = @intCast(count);

    self.seedHeader(cursor.statement, .Parallel, row);

    cursor.counts.invocations += @intCast(count);
    cursor.counts.parallels += 1;
    cursor.statement += 1;
    var published: usize = 0;

    for (symbols) |symbol| {
        if (symbol) |id| {
            bindings[published] = @fromBackingInt(id);
            published += 1;
        }
    }
}

pub fn finishCase(self: *Self, cursor: *const Cursor, block: u32, end: *const Counts, position: u32, label: ?ir.ExprId) Error!void {
    const value = if (label) |id| @backingInt(id) else null;
    const body = try self.finishBlock(cursor, block, end);

    self.commitCase(position, @backingInt(body), value);
}

fn member(index: usize, optional: *const []?u32, required: *const []u32, optional_id: ?u32, required_id: u32) void {
    optional.*[index] = optional_id;
    required.*[index] = required_id;
}

pub fn selection(self: *Self, cursor: *Cursor, subject: ir.ExprId, count: usize, exhaustive: bool) void {
    const row = cursor.counts.selections;

    self.columns.selection_subjects.items[row] = @backingInt(subject);
    self.columns.selection_first.items[row] = cursor.counts.cases;
    self.columns.selection_count.items[row] = @intCast(count);
    self.columns.selection_exhaustive.items[row] = exhaustive;

    self.seedHeader(cursor.statement, .Switch, row);

    cursor.counts.cases += @intCast(count);
    cursor.counts.selections += 1;
    cursor.statement += 1;
}

pub fn commit(self: *Self, cursor: *Cursor, statement: anytype) void {
    const header = statement.header;
    const kind: Kind = @fromBackingInt(@backingInt(header.kind));
    const row = header.row;

    switch (kind) {
        .Evaluate => self.columns.evaluations.items[row] = statement.value.?,
        .Constant => {
            self.columns.constant_values.items[row] = statement.value.?;
            self.columns.constant_symbols.items[row] = statement.symbol.?;
        },
        .Result => self.columns.results.items[row] = statement.value,
        .Parallel => {
            self.columns.parallel_first.items[row] = statement.first.?;
            self.columns.parallel_count.items[row] = statement.count.?;
        },
        .Switch => {
            self.columns.selection_subjects.items[row] = statement.value.?;
            self.columns.selection_first.items[row] = statement.first.?;
            self.columns.selection_count.items[row] = statement.count.?;
            self.columns.selection_exhaustive.items[row] = statement.exhaustive.?;
        },
        else => unreachable,
    }

    self.seedHeader(header.statement, kind, row);

    cursor.statement = header.next_statement;

    cursor.cells()[header.lane] = header.next_row;

    if (statement.member_lane) |lane| cursor.cells()[lane] = statement.next_member.?;
}

pub fn commitCase(self: *Self, position: u32, block: u32, label: ?u32) void {
    member(position, &self.columns.case_values.items, &self.columns.case_bodies.items, label, block);
}

fn seedHeader(self: *Self, statement: u32, kind: Kind, payload: u32) void {
    self.columns.statement_kinds.items[statement] = kind;
    self.columns.statement_payloads.items[statement] = payload;
}

fn allocate(self: *Self, allocator: std.mem.Allocator, comptime names: []const []const u8, count: usize) std.mem.Allocator.Error!void {
    if (count == 0) return;

    inline for (names) |name| {
        const list = &@field(self.columns, name);

        list.items = try allocator.alloc(std.meta.Child(@TypeOf(list.items)), count);
        list.capacity = count;
    }
}
