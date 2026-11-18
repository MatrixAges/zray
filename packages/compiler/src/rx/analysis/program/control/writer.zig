const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Plan = @import("plan.zig");
const Counts = Plan.Counts;
const Kind = std.meta.Child(@FieldType(ir.ControlTable, "statement_kinds"));
const Error = @import("../builder.zig").Error;
const generated = @import("rx_options").generated_graph;
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
pub fn finishBlock(self: *const Self, cursor: *const Cursor, block: u32, end: *const Counts) Error!ir.BlockId {
    if (comptime generated) {
        const rule = @import("generated_rx_control_finish_block");
        const input = self.blockInput(std.meta.Child(rule.Input), cursor, block, end);
        var empty = std.heap.FixedBufferAllocator.init(&.{});
        const complete = zx.columns.invoke(rule.executeValue, empty.allocator(), &input) catch return error.InvalidModule;

        if (!complete) return error.InvalidModule;
    } else if (!std.meta.eql(cursor.counts, end.*) or cursor.statement != end.statements()) {
        return error.InvalidModule;
    }

    return @fromBackingInt(block);
}

fn blockInput(self: *const Self, comptime Input: type, cursor: *const Cursor, block: u32, end: *const Counts) Input {
    comptime {
        const fields = @typeInfo(Counts).@"struct".field_types;

        if (@sizeOf(Counts) != fields.len * @sizeOf(u32)) @compileError("control cursor counts need a packed column layout");
    }

    return .{
        .firsts = self.columns.block_first.items,
        .lengths = self.columns.block_count.items,
        .block = block,
        .statement = cursor.statement,
        .actual = std.mem.asBytes(&cursor.counts),
        .expected = std.mem.asBytes(end),
    };
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
    if (comptime generated) {
        const rule = @import("generated_rx_control_write_binding");
        const Input = std.meta.Child(rule.Input);
        const cells = cursor.cells();

        const input: Input = .{
            .header = &self.headerView(std.meta.Child(@FieldType(Input, "header")), &cells, kind),
            .values = @ptrCast(values),
            .symbols = if (symbols) |buffer| @ptrCast(buffer) else null,
            .symbol = symbol,
            .value = value,
        };

        invoke(rule, input);
    } else {
        const row = if (kind == .Constant) &cursor.counts.constants else &cursor.counts.evaluations;

        values.*[row.*] = value;

        if (symbols) |output| output.*[row.*] = symbol;

        self.seedHeader(cursor.statement, kind, row.*);

        row.* += 1;
        cursor.statement += 1;
    }
}

pub fn result(self: *Self, cursor: *Cursor, value: ?ir.ExprId) void {
    const id = if (value) |item| @backingInt(item) else null;

    if (comptime generated) {
        const rule = @import("generated_rx_control_write_result");
        const Input = std.meta.Child(rule.Input);
        const cells = cursor.cells();

        const input: Input = .{
            .header = &self.headerView(std.meta.Child(@FieldType(Input, "header")), &cells, .Result),
            .values = @ptrCast(&self.columns.results.items),
            .value = id,
        };

        invoke(rule, input);
    } else {
        const row = cursor.counts.results;

        self.columns.results.items[row] = id;

        self.seedHeader(cursor.statement, .Result, row);

        cursor.counts.results += 1;
        cursor.statement += 1;
    }
}

pub fn parallelBranch(self: *Self, position: usize, symbol: ?ir.SymbolId, value: ir.ExprId) void {
    member(position, &self.columns.parallel_symbols.items, &self.columns.parallel_values.items, if (symbol) |id| @backingInt(id) else null, @backingInt(value));
}

pub fn parallel(self: *Self, cursor: *Cursor, count: usize, bindings: []ir.SymbolId) void {
    const symbols = self.columns.parallel_symbols.items[cursor.counts.invocations..][0..count];

    if (comptime generated) {
        const rule = @import("generated_rx_control_write_parallel");
        const Input = std.meta.Child(rule.Input);
        const cells = cursor.cells();

        const input: Input = .{
            .header = &self.headerView(std.meta.Child(@FieldType(Input, "header")), &cells, .Parallel),
            .firsts = @ptrCast(&self.columns.parallel_first.items),
            .counts = @ptrCast(&self.columns.parallel_count.items),
            .count = @intCast(count),
            .symbols = symbols,
            .bindings = if (bindings.len == 0) null else @ptrCast(&bindings),
        };

        invoke(rule, input);
    } else {
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
}

pub fn finishCase(self: *Self, cursor: *const Cursor, block: u32, end: *const Counts, position: u32, label: ?ir.ExprId) Error!void {
    const value = if (label) |id| @backingInt(id) else null;

    if (comptime generated) {
        const rule = @import("generated_rx_control_publish_case");
        const Input = std.meta.Child(rule.Input);
        const check = self.blockInput(std.meta.Child(@FieldType(Input, "block")), cursor, block, end);

        const input: Input = .{
            .block = &check,
            .member = &.{
                .optional = @ptrCast(&self.columns.case_values.items),
                .required = @ptrCast(&self.columns.case_bodies.items),
                .index = position,
                .optional_id = value,
            },
        };

        var empty = std.heap.FixedBufferAllocator.init(&.{});
        const complete = zx.columns.invoke(rule.executeValue, empty.allocator(), &input) catch return error.InvalidModule;

        if (!complete) return error.InvalidModule;
    } else {
        const body = try self.finishBlock(cursor, block, end);

        self.columns.case_values.items[position] = value;
        self.columns.case_bodies.items[position] = @backingInt(body);
    }
}

fn member(index: usize, optional: *const []?u32, required: *const []u32, optional_id: ?u32, required_id: u32) void {
    if (comptime generated) {
        const rule = @import("generated_rx_control_write_member");
        const Input = std.meta.Child(rule.Input);

        const input: Input = .{
            .optional = @ptrCast(optional),
            .required = @ptrCast(required),
            .index = index,
            .optional_id = optional_id,
            .required_id = required_id,
        };

        invoke(rule, input);
    } else {
        optional.*[index] = optional_id;
        required.*[index] = required_id;
    }
}

pub fn selection(self: *Self, cursor: *Cursor, subject: ir.ExprId, count: usize, exhaustive: bool) void {
    if (comptime generated) {
        const rule = @import("generated_rx_control_write_selection");
        const Input = std.meta.Child(rule.Input);
        const cells = cursor.cells();

        const input: Input = .{
            .header = &self.headerView(std.meta.Child(@FieldType(Input, "header")), &cells, .Switch),
            .subjects = @ptrCast(&self.columns.selection_subjects.items),
            .firsts = @ptrCast(&self.columns.selection_first.items),
            .counts = @ptrCast(&self.columns.selection_count.items),
            .flags = @ptrCast(&self.columns.selection_exhaustive.items),
            .subject = @backingInt(subject),
            .count = @intCast(count),
            .exhaustive = exhaustive,
        };

        invoke(rule, input);
    } else {
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
}

pub fn headerView(self: *const Self, comptime Header: type, cursor: *const []u32, kind: Kind) Header {
    comptime {
        if (@sizeOf(Kind) != @sizeOf(u8) or @sizeOf(bool) != @sizeOf(u8)) @compileError("control tags and flags must occupy one byte");
    }

    return .{
        .kinds = @ptrCast(&self.columns.statement_kinds.items),
        .payloads = @ptrCast(&self.columns.statement_payloads.items),
        .cursor = @ptrCast(cursor),
        .kind = @backingInt(kind),
    };
}

fn seedHeader(self: *Self, statement: u32, kind: Kind, payload: u32) void {
    self.columns.statement_kinds.items[statement] = kind;
    self.columns.statement_payloads.items[statement] = payload;
}

fn invoke(comptime rule: type, input: std.meta.Child(rule.Input)) void {
    var empty = std.heap.FixedBufferAllocator.init(&.{});

    zx.columns.invoke(rule.executeValue, empty.allocator(), &input) catch unreachable;
}

fn allocate(self: *Self, allocator: std.mem.Allocator, comptime names: []const []const u8, count: usize) std.mem.Allocator.Error!void {
    if (count == 0) return;

    inline for (names) |name| {
        const list = &@field(self.columns, name);

        list.items = try allocator.alloc(std.meta.Child(@TypeOf(list.items)), count);
        list.capacity = count;
    }
}
