const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");
const Api = @import("../expressions/evaluate.zig").Api;
const Consumer = @import("../iteration_consumer.zig").Consumer;
const Error = Lower.Error;
const entry = @import("generated_lower_loop_consumer");
const Input = std.meta.Child(entry.Input);
const Source = std.meta.Child(@FieldType(Input, "source"));

const Frame = struct {
    lowering: *Lower,
    selected: Consumer,
    iteration: ir.ExprId,
    cache: Api.LoopConsumerCache = undefined,
    facts: Api.LoopConsumerFacts = undefined,
    fn borrow(handle: *const anyopaque) *Frame {
        return @ptrCast(@alignCast(@constCast(handle)));
    }
};

pub fn lower(self: *Lower, selected: Consumer, iteration: ir.ExprId) Error!?node.ExpressionId {
    var frame: Frame = .{ .lowering = self, .selected = selected, .iteration = iteration };
    const program: *const ir.Program = &self.program;
    const types = ir.TypeTable.borrow(std.meta.Child(@FieldType(Source, "types")), program.types);

    const source: Source = .{
        .types = &types,
        .table = zx.columns.pointer(@FieldType(Source, "table"), &program.expressions),
        .symbol = @backingInt(selected.symbol),
        .value = @backingInt(iteration),
        .result = @backingInt(selected.result),
    };

    var arena = std.heap.ArenaAllocator.init(self.workspace);
    var buffer: [std.heap.page_size_min]u8 = undefined;
    var scratch = std.heap.BufferFirstAllocator.init(&buffer, arena.allocator());

    defer arena.deinit();

    const input: Input = .{ .frame = @ptrCast(&frame), .source = &source };
    const result = entry.executeIn(scratch.allocator(), &input) catch |err| return @import("../construction/publication.zig").failure(err);

    return if (result) |id| @fromBackingInt(id) else null;
}

pub fn loopConsumerFacts(handle: *const anyopaque) *const Api.LoopConsumerFacts {
    const frame = Frame.borrow(handle);
    const self = frame.lowering;

    frame.cache = self.cache.view(Api.LoopConsumerCache);
    frame.facts = .{ .cache = &frame.cache, .transaction = self.transaction(), .capture = self.capture != null };

    return &frame.facts;
}

pub fn consumeVectorLoop(handle: *const anyopaque) Error!?u32 {
    const frame = Frame.borrow(handle);
    const result = try @import("../simd/iteration.zig").lower(frame.lowering, frame.iteration, frame.selected);

    return if (result) |id| @backingInt(id) else null;
}

pub fn consumeLoop(handle: *const anyopaque, scalar: bool) Error!?u32 {
    const frame = Frame.borrow(handle);
    var selected = frame.selected;

    if (scalar) selected.layout = false;

    const result = try @import("../iteration.zig").consume(frame.lowering, frame.iteration, selected);

    return if (result) |id| @backingInt(id) else null;
}
