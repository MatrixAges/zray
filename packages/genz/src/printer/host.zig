const std = @import("std");
const zx = @import("zx");
const Storage = @import("../node/storage.zig");
const view = @import("../node/view.zig");
const generated = @import("generated_printer");
const Input = @typeInfo(generated.Input).pointer.child;
const Source = @typeInfo(@FieldType(Input, "source")).pointer.child;

pub fn renderStored(allocator: std.mem.Allocator, nodes: *Storage, selected: @import("../node/stored.zig").Declarations) std.mem.Allocator.Error![]u8 {
    const expressions = view.rows(@typeInfo(@FieldType(Source, "expressions")).pointer.child, &nodes.expressions);
    const statements = view.rows(@typeInfo(@FieldType(Source, "statements")).pointer.child, &nodes.statements);
    const declaration_rows = view.rows(@typeInfo(@FieldType(Source, "declarations")).pointer.child, &nodes.declaration_rows);
    const fields = view.members(@typeInfo(@FieldType(Source, "fields")).pointer.child, &nodes.field_columns);
    const arms = view.members(@typeInfo(@FieldType(Source, "arms")).pointer.child, &nodes.arm_columns);

    const source = Source{
        .expressions = &expressions,
        .statements = &statements,
        .declarations = &declaration_rows,
        .fields = &fields,
        .arms = &arms,
        .first = selected.start,
        .count = selected.len,
    };

    var arena = zx.Arena.init(nodes.allocator);

    defer arena.deinit();

    var output: zx.memory.ByteWriter = .{ .allocator = allocator };

    defer output.deinit();

    const input: Input = .{ .source = &source, .output = @ptrCast(&output) };

    generated.executeIn(arena.allocator(), &input) catch |err| switch (err) {
        error.OutOfMemory, error.Overflow => return error.OutOfMemory,
        else => unreachable,
    };

    return output.finish();
}
