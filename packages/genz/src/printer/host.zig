const std = @import("std");
const zx = @import("zx");
const Storage = @import("../node/storage.zig");
const view = @import("../node/view.zig");
const generated = @import("generated_printer");
const Input = @typeInfo(generated.Input).pointer.child;
const Source = @typeInfo(@FieldType(Input, "source")).pointer.child;

pub fn renderStored(allocator: std.mem.Allocator, workspace: std.mem.Allocator, nodes: *Storage, selected: @import("../node/stored.zig").Declarations, comptime scoped: bool) std.mem.Allocator.Error![]u8 {
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

    var arena = zx.Arena.init(workspace);

    defer arena.deinit();

    var output: zx.memory.ByteWriter = .{ .allocator = allocator };

    defer output.deinit();

    if (scoped) {
        var root = source;
        root.count = 1;
        const mark = arena.checkpoint();

        for (0..selected.len) |offset| {
            root.first = selected.start + @as(u32, @intCast(offset));

            try write(arena.allocator(), &root, &output);

            arena.rewindRetainingCapacity(mark);
        }
    } else {
        try write(arena.allocator(), &source, &output);
    }

    return output.finish();
}

fn write(allocator: std.mem.Allocator, source: *const Source, output: *zx.memory.ByteWriter) std.mem.Allocator.Error!void {
    const input: Input = .{ .source = source, .output = @ptrCast(output) };

    generated.executeIn(allocator, &input) catch |err| switch (err) {
        error.OutOfMemory, error.Overflow => return error.OutOfMemory,
        else => unreachable,
    };
}
