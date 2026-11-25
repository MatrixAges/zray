const std = @import("std");
const ir = @import("zx").ir;
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");
const view = @import("../../node/view.zig");
const rows = @import("../construction/publication.zig");
const evaluate = @import("../expressions/evaluate.zig");
const generated = @import("genz_options").generated_analysis;
const seed = @import("root_seed.zig");
const Started = struct { block: node.Block, value: node.ExpressionId };

pub fn start(self: *Lower, id: ir.ExprId, concurrent: bool) Lower.Error!node.ExpressionId {
    if (!generated) return seed.start(self, id, concurrent);

    return (try launch(self, id, concurrent, null)).value;
}

pub fn bind(self: *Lower, name: []const u8, id: ir.ExprId, concurrent: bool) Lower.Error!node.Block {
    if (!generated) {
        var storage: [2]node.Statement = undefined;
        var output = std.ArrayList(node.Statement).initBuffer(&storage);

        try seed.bind(self, &output, name, id, concurrent);

        return self.builder.statements(output.items);
    }

    return (try launch(self, id, concurrent, name)).block;
}

fn launch(self: *Lower, id: ir.ExprId, concurrent: bool, name: ?[]const u8) Lower.Error!Started {
    const entry = @import("generated_execute_task_start");
    const Input = std.meta.Child(entry.Input);
    const captures = self.program.expression(id).value.task.captures;
    const stack = self.stack_symbols.view(std.meta.Child(@FieldType(Input, "stack")));
    var used = std.mem.sliceAsBytes(self.used);

    comptime std.debug.assert(@sizeOf(bool) == 1);

    var scratch: std.heap.ArenaAllocator = .init(self.workspace);
    var buffer: [std.heap.page_size_min]u8 = undefined;
    var memory: std.heap.BufferFirstAllocator = .init(&buffer, scratch.allocator());
    var origin: rows.OriginBuffer = .{};

    defer scratch.deinit();

    const input: Input = .{
        .frame = @ptrCast(self),
        .writer = @ptrCast(self),
        .origin = @ptrCast(&origin),
        .id = @backingInt(id),
        .process = self.entry_flags.body_process,
        .concurrent = concurrent,
        .symbols = view.slice(@FieldType(Input, "symbols"), captures),
        .names = self.names,
        .stack = &stack,
        .used = @ptrCast(&used),
        .name = name,
    };

    const output = entry.executeIn(memory.allocator(), &input) catch |err| return rows.failure(err);

    return .{ .value = @fromBackingInt(output.value), .block = .{ .start = output.first, .len = output.count } };
}

pub fn buildTaskWorker(handle: *const anyopaque, task: u32, process: bool) Lower.Error!u32 {
    return @backingInt(try @import("worker.zig").lower(evaluate.borrow(handle), @fromBackingInt(task), process));
}

pub fn publishTaskEffects(handle: *const anyopaque, allocator: bool, io: bool, process: bool) void {
    const self = evaluate.borrow(handle);

    self.uses_allocator = self.uses_allocator or allocator;
    self.uses_io = self.uses_io or io;
    self.uses_process = self.uses_process or process;
}

pub fn wait(self: *Lower, child: ir.ExprId) Lower.Error!node.ExpressionId {
    if (!generated) return seed.wait(self, child);

    return complete(self, child, false);
}

pub fn cancel(self: *Lower, child: ir.ExprId) Lower.Error!node.ExpressionId {
    if (!generated) return seed.cancel(self, child);

    return complete(self, child, true);
}

fn complete(self: *Lower, child: ir.ExprId, canceling: bool) Lower.Error!node.ExpressionId {
    const entry = @import("generated_execute_task_future");
    var scratch: std.heap.ArenaAllocator = .init(self.workspace);
    var buffer: [std.heap.page_size_min]u8 = undefined;
    var memory: std.heap.BufferFirstAllocator = .init(&buffer, scratch.allocator());
    var origin: rows.OriginBuffer = .{};

    defer scratch.deinit();

    const input: std.meta.Child(entry.Input) = .{
        .frame = @ptrCast(self),
        .writer = @ptrCast(self),
        .origin = @ptrCast(&origin),
        .child = @backingInt(child),
        .cancel = canceling,
        .inline_task = self.program.expression(child).value == .task,
    };

    const result = entry.executeIn(memory.allocator(), &input) catch |err| return rows.failure(err);

    return @fromBackingInt(result);
}

pub fn lowerTaskOperand(handle: *const anyopaque, expression: u32) Lower.Error!u32 {
    return @backingInt(try evaluate.borrow(handle).expr(@fromBackingInt(expression)));
}

pub fn startInlineTask(handle: *const anyopaque, task: u32, name: []const u8) Lower.Error!u64 {
    return rows.packSpan(try bind(evaluate.borrow(handle), name, @fromBackingInt(task), false));
}

pub fn finishTaskBlock(handle: *const anyopaque, first: u32, count: u32, value: u32) Lower.Error!u32 {
    const self = evaluate.borrow(handle);
    const result = try @import("../aggregate.zig").finishStored(self, .{ .start = first, .len = count }, @fromBackingInt(value), null);

    return @backingInt(result);
}

pub fn parallel(self: *Lower, type_id: ir.TypeId, branches: @FieldType(@FieldType(ir.ExpressionRow, "value"), "parallel")) Lower.Error!node.ExpressionId {
    if (!generated) return seed.parallel(self, type_id, branches);

    return @import("parallel.zig").lower(self, type_id, branches);
}
