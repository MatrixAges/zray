const ir = @import("zx").ir;
const Builder = @import("builder.zig");
const Mapping = @import("mapping.zig");
const operands = @import("linking/operands/host.zig");
const enabled = @import("rx_options").generated_graph;

pub fn append(builder: *Builder, mapping: *const Mapping, table: *const ir.ExpressionTable, index: usize) Builder.Error!usize {
    if (comptime !enabled) return @import("linking/operands/seed.zig").append(builder, mapping, table, index);

    const storage = &builder.expressions;
    const allocator = builder.allocator;
    const payload = table.payloads[index];

    return switch (table.kinds[index]) {
        .List, .Tuple, .Template => operands.sequence(storage, allocator, mapping, table, payload),
        .ListOperation => operands.collection(storage, allocator, mapping, table, payload),
        .Transform => operands.transform(storage, allocator, mapping, table, payload),
        .Scope => operands.scope(storage, allocator, mapping, table, payload),
        .Match => operands.match(storage, allocator, mapping, table, payload),
        .Object => operands.object(storage, allocator, mapping, table, payload),
        else => unreachable,
    };
}
