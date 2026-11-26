const std = @import("std");
const zx = @import("zx");
const Storage = @import("../node/storage.zig");
const view = @import("../node/view.zig");
const schema = @import("../node/schema.zig");
const Range = @import("../node/stored.zig").Declarations;
const generated = @import("generated_printer");
const Input = @typeInfo(generated.Input).pointer.child;
const Source = schema.Source;
const selection = @import("generated_printer_selection");
const Selection = std.meta.Child(selection.Input);
const Ranges = std.meta.Child(@typeInfo(@FieldType(Selection, "ranges")).optional.child);
const Shape = enum { range, scoped, indices };

pub fn renderStored(allocator: std.mem.Allocator, workspace: std.mem.Allocator, nodes: *Storage, ranges: []const Range, comptime scoped: bool) std.mem.Allocator.Error![]u8 {
    if (scoped) return render(allocator, workspace, nodes, .scoped, ranges);

    return render(allocator, workspace, nodes, .range, ranges[0]);
}

pub fn renderIndices(allocator: std.mem.Allocator, workspace: std.mem.Allocator, nodes: *Storage, indices: []const u32) (std.mem.Allocator.Error || error{InvalidAst})![]u8 {
    return render(allocator, workspace, nodes, .indices, indices);
}

fn render(
    allocator: std.mem.Allocator,
    workspace: std.mem.Allocator,
    nodes: *Storage,
    comptime shape: Shape,
    rows: switch (shape) {
        .range => Range,
        .scoped => []const Range,
        .indices => []const u32,
    },
) (std.mem.Allocator.Error || if (shape == .indices) error{InvalidAst} else error{})![]u8 {
    const expressions = view.rows(schema.Expressions, &nodes.expressions);
    const statements = view.rows(schema.Statements, &nodes.statements);
    const declaration_rows = view.rows(schema.Declarations, &nodes.declaration_rows);
    const fields = view.members(schema.Fields, &nodes.field_columns);
    const arms = view.members(schema.Arms, &nodes.arm_columns);

    const source = Source{
        .expressions = &expressions,
        .statements = &statements,
        .declarations = &declaration_rows,
        .fields = &fields,
        .arms = &arms,
        .first = if (shape == .range) rows.start else 0,
        .count = if (shape == .range) rows.len else 0,
    };

    var arena = zx.Arena.init(workspace);

    defer arena.deinit();

    var output: zx.memory.ByteWriter = .{ .allocator = allocator };

    defer output.deinit();

    if (comptime shape == .range) {
        try write(arena.allocator(), &source, &output);
    } else {
        const starts = if (shape == .scoped) zx.memory.borrowReadColumn(u32, "start", rows) else {};
        const lengths = if (shape == .scoped) zx.memory.borrowReadColumn(u32, "len", rows) else {};

        const ranges: Ranges = if (shape == .scoped) .{
            .starts = @ptrCast(&starts),
            .lengths = @ptrCast(&lengths),
            .count = rows.len,
        } else undefined;

        const input: Selection = .{
            .source = zx.columns.pointer(@FieldType(Selection, "source"), &source),
            .writer = @ptrCast(&output),
            .ranges = if (shape == .scoped) &ranges else null,
            .indices = if (shape == .indices) rows else null,
        };

        const valid = zx.columns.invoke(selection.executeValue, arena.allocator(), &input) catch |err| return failure(err);

        if (comptime shape == .indices) {
            if (!valid) return error.InvalidAst;
        } else {
            std.debug.assert(valid);
        }
    }

    return output.finish();
}

fn write(allocator: std.mem.Allocator, source: *const Source, output: *zx.memory.ByteWriter) std.mem.Allocator.Error!void {
    const input: Input = .{ .source = source, .output = @ptrCast(output) };

    generated.executeIn(allocator, &input) catch |err| return failure(err);
}

fn failure(err: anyerror) std.mem.Allocator.Error {
    return switch (err) {
        error.OutOfMemory, error.Overflow => error.OutOfMemory,
        else => unreachable,
    };
}
