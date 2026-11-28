const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");
const Consumer = @import("../iteration_consumer.zig").Consumer;
const publication = @import("../construction/publication.zig");
const entry = @import("generated_lower_loop_consumer");
const Input = std.meta.Child(entry.Input);
const Source = std.meta.Child(@FieldType(Input, "source"));
const Facts = std.meta.Child(@FieldType(Input, "facts"));
const Cache = std.meta.Child(@FieldType(Facts, "cache"));
const Phase = @FieldType(Input, "phase");
const Output = std.meta.Child(entry.Output);

pub fn lower(self: *Lower, selected: Consumer, iteration: ir.ExprId) Lower.Error!?node.ExpressionId {
    const program: *const ir.Program = &self.program;
    const types = ir.TypeTable.borrow(std.meta.Child(@FieldType(Source, "types")), program.types);

    const source: Source = .{
        .types = &types,
        .table = zx.columns.pointer(@FieldType(Source, "table"), &program.expressions),
        .symbol = @backingInt(selected.symbol),
        .value = @backingInt(iteration),
        .result = @backingInt(selected.result),
    };

    var phase: Phase = .Initial;

    while (true) {
        const output = try decide(self, &source, phase);

        switch (output.decision) {
            .None => return null,
            .Simd => {
                if (try @import("../simd/iteration.zig").lower(self, iteration, selected)) |id| return id;

                phase = .AfterSimd;
            },
            .Scalar => return @import("../iteration.zig").consume(self, iteration, .{
                .symbol = selected.symbol,
                .result = selected.result,
                .layout = false,
            }),
            .Layout => {
                const result = try @import("../iteration.zig").consume(self, iteration, selected);

                if (result != null or !output.retry) return result;

                phase = .AfterLayout;
            },
        }
    }
}

fn decide(self: *const Lower, source: *const Source, phase: Phase) Lower.Error!Output {
    const cache = self.cache.view(Cache);
    const facts: Facts = .{ .cache = &cache, .transaction = self.transaction(), .capture = self.capture != null };
    const input: Input = .{ .source = source, .facts = &facts, .phase = phase };
    var arena = std.heap.ArenaAllocator.init(self.workspace);
    var buffer: [std.heap.page_size_min]u8 = undefined;
    var scratch = std.heap.BufferFirstAllocator.init(&buffer, arena.allocator());

    defer arena.deinit();

    const output = entry.executeIn(scratch.allocator(), &input) catch |err| return publication.failure(err);

    return output.*;
}
