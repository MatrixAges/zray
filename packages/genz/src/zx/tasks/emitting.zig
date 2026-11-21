const std = @import("std");
const zx = @import("zx");
const node = @import("../../node.zig");
const view = @import("../../node/view.zig");
const Lower = @import("../lower.zig");

pub fn open(self: *Lower, inline_task: bool) Lower.Error!?[]const u8 {
    const entry = @import("generated_task_future_open");
    const input: std.meta.Child(entry.Input) = .{ .serial = self.serial, .inline_task = inline_task };
    const output = zx.columns.invoke(entry.executeValue, self.allocator, &input) catch |err| return failure(err);

    self.serial = @intCast(output.serial);

    return output.name;
}

pub const Started = struct { block: node.Block, value: node.ExpressionId };

pub fn start(self: *Lower, worker: node.ExpressionId, id: zx.ir.ExprId, process: bool, concurrent: bool, name: ?[]const u8) Lower.Error!Started {
    const entry = @import("generated_task_start");
    const Input = std.meta.Child(entry.Input);
    const bases = context(std.meta.Child(@FieldType(Input, "bases")), self);
    const stack = self.stack_symbols.view(std.meta.Child(@FieldType(Input, "stack")));
    const captures = self.program.expression(id).value.task.captures;
    const used = std.mem.sliceAsBytes(self.used);

    comptime std.debug.assert(@sizeOf(bool) == 1);

    const input: Input = .{
        .worker = @backingInt(worker),
        .process = process,
        .concurrent = concurrent,
        .symbols = view.slice(@FieldType(Input, "symbols"), captures),
        .names = self.names,
        .stack = &stack,
        .used = @ptrCast(&used),
        .name = name,
        .bases = &bases,
    };

    var scratch = std.heap.ArenaAllocator.init(self.workspace);
    var buffer: [std.heap.page_size_min]u8 = undefined;
    var memory = std.heap.BufferFirstAllocator.init(&buffer, scratch.allocator());

    defer scratch.deinit();

    const result = entry.executeIn(memory.allocator(), &input) catch |err| return failure(err);

    if (!result.valid) return error.OutOfMemory;

    const expressions = view.join(result.expressions.*, result.forms.*);

    try append(self, &self.builder.nodes.expressions, &expressions);

    const block: node.Block = if (result.binding) |binding| written: {
        _ = try self.builder.publishStatements(&.{}, binding.statements);

        break :written .{ .start = binding.first, .len = binding.count };
    } else .{};

    return .{ .block = block, .value = @fromBackingInt(result.root) };
}

pub fn complete(self: *Lower, started: node.Block, value: ?node.ExpressionId, name: ?[]const u8, cancel: bool) Lower.Error!node.ExpressionId {
    const entry = @import("generated_task_future_complete");
    const Input = std.meta.Child(entry.Input);
    const bases = context(std.meta.Child(@FieldType(Input, "bases")), self);

    const input: Input = .{
        .value = if (value) |id| @backingInt(id) else null,
        .name = name,
        .cancel = cancel,
        .bases = &bases,
    };

    var scratch = std.heap.ArenaAllocator.init(self.workspace);
    var buffer: [std.heap.page_size_min]u8 = undefined;
    var memory = std.heap.BufferFirstAllocator.init(&buffer, scratch.allocator());

    defer scratch.deinit();

    const result = entry.executeIn(memory.allocator(), &input) catch |err| return failure(err);

    if (!result.valid) return error.OutOfMemory;

    try append(self, &self.builder.nodes.expressions, result.expressions);

    const root: node.ExpressionId = @fromBackingInt(result.root);

    if (!result.wrap) return root;

    const completed = try self.builder.publishStatements(&.{}, result.statements);

    const body = try @import("../../node/blocks.zig").tail(
        self.allocator,
        self.builder.nodes,
        &.{ started.start, completed.start },
        &.{ started.len, completed.len },
    );

    return @import("../aggregate.zig").finishStored(self, body, root, null);
}

pub inline fn context(comptime Bases: type, self: *const Lower) Bases {
    return .{
        .capture = if (self.capture) |capture| &.{
            .name = capture.name,
            .label = capture.label,
            .failure = @backingInt(capture.failure),
        } else null,
        .expression_base = @intCast(self.builder.nodes.expressions.tags.items.len),
        .statement_base = @intCast(self.builder.nodes.statements.tags.items.len),
        .field_base = @intCast(self.builder.nodes.field_columns.count()),
        .serial = self.serial,
    };
}

pub fn append(self: *Lower, target: anytype, source: anytype) Lower.Error!void {
    @import("../../node/import_rows.zig").appendBorrowingText(self.allocator, target, source) catch |err| return failure(err);
}

pub fn failure(err: anyerror) Lower.Error {
    return switch (err) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => error.OutOfMemory,
        else => unreachable,
    };
}
