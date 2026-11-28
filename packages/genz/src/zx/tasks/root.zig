const std = @import("std");
const ir = @import("zx").ir;
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");
const view = @import("../../node/view.zig");
const rows = @import("../construction/publication.zig");
const context = @import("../construction/context.zig");
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
    var scratch: std.heap.ArenaAllocator = .init(self.workspace);
    var buffer: [std.heap.page_size_min]u8 = undefined;
    var memory: std.heap.BufferFirstAllocator = .init(&buffer, scratch.allocator());

    defer scratch.deinit();

    const process = self.entry_flags.body_process;

    self.uses_allocator = true;
    self.uses_io = true;
    self.uses_process = self.uses_process or process;

    const worker = try @import("worker.zig").lower(self, id, process);

    const input: Input = .{
        .writer = @ptrCast(self),
        .bases = &context.snapshot(std.meta.Child(@FieldType(Input, "bases")), self),
        .worker = @backingInt(worker),
        .process = process,
        .concurrent = concurrent,
        .symbols = view.slice(@FieldType(Input, "symbols"), captures),
        .names = self.names,
        .stack = &stack,
        .name = name,
    };

    const output = entry.executeIn(memory.allocator(), &input) catch |err| return rows.failure(err);

    for (captures) |symbol| self.used[@backingInt(symbol)] = true;

    return .{ .value = @fromBackingInt(output.value), .block = .{ .start = output.first, .len = output.count } };
}

pub fn publishTaskEffects(handle: *anyopaque, allocator: bool, io: bool, process: bool) void {
    const self = evaluate.borrow(handle);

    self.uses_allocator = self.uses_allocator or allocator;
    self.uses_io = self.uses_io or io;
    self.uses_process = self.uses_process or process;
}

pub fn startInlineTask(handle: *anyopaque, task: u32, name: []const u8, concurrent: bool) Lower.Error!u64 {
    return rows.packSpan(try bind(evaluate.borrow(handle), name, @fromBackingInt(task), concurrent));
}

pub fn parallel(self: *Lower, type_id: ir.TypeId, branches: @FieldType(@FieldType(ir.ExpressionRow, "value"), "parallel")) Lower.Error!node.ExpressionId {
    if (!generated) return seed.parallel(self, type_id, branches);

    return @import("parallel.zig").lower(self, type_id, branches);
}
