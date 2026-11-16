const std = @import("std");
const ir = @import("zx").ir;
const Builder = @import("builder.zig");
const linking = @import("linking.zig");
const Mapping = @import("mapping.zig");
const fixed = @import("linking/fixed.zig");
const headers = @import("linking/headers.zig");
const literals = @import("linking/literals/host.zig");
const generated = @import("rx_options").generated_graph;

/// Borrowed symbol names and string literals must live as long as the destination program.
pub fn inlineValue(builder: *Builder, program: ir.Program, borrow_text: bool) Builder.Error!ir.ExprId {
    var buffer: [std.heap.page_size_min / 4]u8 = undefined;
    var scratch = std.heap.BufferFirstAllocator.init(&buffer, builder.linking_scratch.allocator());
    defer _ = builder.linking_scratch.reset(.retain_capacity);
    const plan = try linking.plan(scratch.allocator(), builder, program);
    const storage = &builder.expressions;
    const base = storage.count();

    try storage.reserveHeaders(builder.allocator, plan.count);

    const local_first = plan.bindings.len + 1;

    var mapping = Mapping{
        .bindings = plan.bindings,
        .locals_base = builder.symbols.count(),
        .symbol_count = program.symbols.count(),
        .expressions = plan.rows,
    };

    const payloads = storage.payloads.unusedCapacitySlice()[0..plan.count];

    if (comptime generated) {
        try @import("linking/symbols.zig").publish(builder, program.symbols, local_first, borrow_text);

        const literal_bases = try literals.publish(builder, &program.expressions, borrow_text);

        try @import("linking/payload.zig").publish(builder, &mapping, &program.expressions, literal_bases, base, payloads);
    } else {
        try builder.symbols.appendFresh(builder.allocator, program.symbols, local_first, borrow_text);

        for (plan.rows, 0..) |row, index| {
            if (row == linking.missing) continue;

            mapping.available = index;

            const payload = switch (program.expressions.kinds[index]) {
                .List, .Tuple, .Template, .ListOperation, .Transform, .Scope, .Match, .Object => try @import("linking/operands/seed.zig").append(builder, &mapping, &program.expressions, index),
                else => try fixed.append(builder, &mapping, &program.expressions, index, borrow_text),
            };

            payloads[row - base] = @intCast(payload);
        }
    }

    try headers.publish(storage, &program.expressions, plan.rows, plan.count);

    return plan.returned;
}
