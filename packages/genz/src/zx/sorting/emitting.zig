const std = @import("std");
const node = @import("../../node.zig");
const view = @import("../../node/view.zig");
const Lower = @import("../lower.zig");

pub const Expression = struct {
    name: []const u8,
    source: node.ExpressionId,
    reuse: node.ExpressionId,
    environment: node.ExpressionId,
    errors: ?[]const []const u8,
    io: bool,
    process: bool,
    selected: bool,
    headered: node.ExpressionId,
};

pub const Result = struct { value: node.ExpressionId, headered: node.ExpressionId };

pub fn reserve(self: *Lower, index: usize) Lower.Error![]const u8 {
    const entry = @import("generated_sorting_reserve");
    const input: std.meta.Child(entry.Input) = .{ .index = index, .expression_base = @intCast(self.builder.nodes.expressions.tags.items.len) };
    var scratch = std.heap.ArenaAllocator.init(self.workspace);
    var buffer: [std.heap.page_size_min]u8 = undefined;
    var memory = std.heap.BufferFirstAllocator.init(&buffer, scratch.allocator());

    defer scratch.deinit();

    const result = entry.executeIn(memory.allocator(), &input) catch |err| return failure(err);

    if (!result.valid) return error.OutOfMemory;

    try append(self, &self.builder.nodes.expressions, result.expressions);

    const names = try self.task_declarations.appendConstants(self.allocator, result.declarations, false);

    return names[0];
}

pub fn publish(self: *Lower, slot: usize, name: []const u8, entries: @import("../../node/stored.zig").Declarations) Lower.Error!void {
    const entry = @import("generated_sorting_publish");

    const input: std.meta.Child(entry.Input) = .{
        .name = name,
        .expression_base = @intCast(self.builder.nodes.expressions.tags.items.len),
        .first = entries.start,
        .count = entries.len,
    };

    var scratch = std.heap.ArenaAllocator.init(self.workspace);
    var buffer: [std.heap.page_size_min]u8 = undefined;
    var memory = std.heap.BufferFirstAllocator.init(&buffer, scratch.allocator());

    defer scratch.deinit();

    const result = entry.executeIn(memory.allocator(), &input) catch |err| return failure(err);

    if (!result.valid) return error.OutOfMemory;
    try append(self, &self.builder.nodes.expressions, result.expressions);
    try self.task_declarations.replaceConstant(self.allocator, slot, result.declarations);
}

pub fn reuse(self: *Lower, in_place: bool, selected: bool) Lower.Error!?node.ExpressionId {
    const entry = @import("generated_sorting_reuse");
    const input: std.meta.Child(entry.Input) = .{ .in_place = in_place, .selected = selected, .base = @intCast(self.builder.nodes.expressions.tags.items.len) };
    var scratch = std.heap.ArenaAllocator.init(self.workspace);
    var buffer: [std.heap.page_size_min]u8 = undefined;
    var memory = std.heap.BufferFirstAllocator.init(&buffer, scratch.allocator());

    defer scratch.deinit();

    const result = entry.executeIn(memory.allocator(), &input) catch |err| return failure(err);

    if (!result.valid) return error.OutOfMemory;
    if (result.writable) return null;
    try append(self, &self.builder.nodes.expressions, result.expressions);

    return @fromBackingInt(result.root);
}

pub fn expression(self: *Lower, body: *@import("../../node/blocks.zig").Sequence, args: Expression) Lower.Error!Result {
    const entry = @import("generated_sorting_expression");
    const Input = std.meta.Child(entry.Input);
    const Bases = std.meta.Child(@FieldType(Input, "bases"));

    const bases: Bases = .{
        .capture = if (self.capture) |capture| &.{ .name = capture.name, .label = capture.label, .failure = @backingInt(capture.failure) } else null,
        .expression_base = @intCast(self.builder.nodes.expressions.tags.items.len),
        .statement_base = @intCast(self.builder.nodes.statements.tags.items.len),
        .field_base = @intCast(self.builder.nodes.field_columns.count()),
        .serial = self.serial,
    };

    const input: Input = .{
        .name = args.name,
        .source = @backingInt(args.source),
        .reuse = @backingInt(args.reuse),
        .environment = @backingInt(args.environment),
        .errors = args.errors,
        .io = args.io,
        .process = args.process,
        .selected = args.selected,
        .headered = @backingInt(args.headered),
        .bases = &bases,
    };

    var scratch = std.heap.ArenaAllocator.init(self.workspace);
    var buffer: [std.heap.page_size_min]u8 = undefined;
    var memory = std.heap.BufferFirstAllocator.init(&buffer, scratch.allocator());

    defer scratch.deinit();

    const result = entry.executeIn(memory.allocator(), &input) catch |err| return failure(err);

    if (!result.valid) return error.OutOfMemory;

    var expressions = view.join(view.join(result.expressions.*, result.forms.*), result.extra.*);
    const name = try self.allocator.dupe(u8, result.name);
    const identifiers = try memory.allocator().dupe([]const u8, expressions.identifier);

    identifiers[@intCast(result.name_slot)] = name;

    expressions.identifier = identifiers;

    var variables = result.variables.*;
    const names = [_][]const u8{name};

    variables.variable_name = &names;

    const statements = view.join(result.statements.*, variables);

    try append(self, &self.builder.nodes.expressions, &expressions);

    _ = @import("../../node/import_fields.zig").appendBorrowingText(self.allocator, &self.builder.nodes.field_columns, result.fields) catch |err| return failure(err);
    @import("../../node/import_statements.zig").appendBorrowingText(self.allocator, body, &statements) catch |err| return failure(err);
    self.serial = @intCast(result.serial);

    return .{ .value = @fromBackingInt(result.root), .headered = @fromBackingInt(result.headered) };
}

fn append(self: *Lower, target: anytype, source: anytype) Lower.Error!void {
    @import("../../node/import_rows.zig").appendBorrowingText(self.allocator, target, source) catch |err| return failure(err);
}

fn failure(err: anyerror) Lower.Error {
    return switch (err) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => error.OutOfMemory,
        else => unreachable,
    };
}
