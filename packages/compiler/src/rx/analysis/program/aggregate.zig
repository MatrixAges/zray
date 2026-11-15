const ir = @import("zx").ir;
const Builder = @import("builder.zig");
const Mapping = @import("mapping.zig");
const operands = @import("linking/operands.zig");

pub fn append(builder: *Builder, mapping: *const Mapping, table: *const ir.ExpressionTable, index: usize) Builder.Error!usize {
    const storage = &builder.expressions;
    const row = table.at(index);
    const payload = table.payloads[index];

    try storage.reservePayload(builder.allocator, row);

    return switch (row.value) {
        .list, .tuple, .template => |items| operands.sequence(storage, mapping, @ptrCast(items)),
        .list_operation => |operation| operands.collection(storage, mapping, operation, @backingInt(table.collection_kinds[payload])),
        .transform => |operation| operands.transform(storage, mapping, operation, @backingInt(table.transform_kinds[payload])),
        .scope => |value| operands.scope(storage, mapping, value),
        .match_expr => |value| operands.match(storage, mapping, value),
        .object => |value| operands.object(storage, mapping, value),
        else => unreachable,
    };
}
