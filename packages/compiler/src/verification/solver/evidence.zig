const std = @import("std");
const zx = @import("zx");
const frontend = @import("frontend");
const Conditions = @import("../conditions.zig");
const Template = struct { path: []const u8, source: []const u8 };
const Span = struct { end: u64, start: u64 };

const Origin = struct {
    expanded: *const Span,
    path: []const u8,
    reference: *const Span,
    source: []const u8,
};

const Source = struct {
    original: ?[]const u8,
    path: []const u8,
    source: []const u8,
    template_origins: []const *const Origin,
    templates: []const *const Template,
};

const Binding = struct { path: []const u8, symbol: []const u8, type_id: u32 };

pub fn encode(comptime Result: type, allocator: std.mem.Allocator, sources: []const frontend.project.Source, entry: []const u8, inputs: []const Conditions.Input, program: *const zx.ir.Program) std.mem.Allocator.Error!Result {
    const source_rows = try zx.columns.bridge([]const *const Source, allocator, sources);
    const input_rows = try bindingRows([]const *const Binding, allocator, inputs);

    return .{
        .sources = try jsonMember(allocator, source_rows),
        .entry = try jsonMember(allocator, entry),
        .version = try jsonMember(allocator, program.version),
        .types = try jsonMember(allocator, &program.types),
        .inputs = try jsonMember(allocator, input_rows),
        .program = try jsonMember(allocator, program),
    };
}

fn jsonMember(allocator: std.mem.Allocator, value: anytype) std.mem.Allocator.Error![]const u8 {
    const nested = try std.json.Stringify.valueAlloc(allocator, [_]@TypeOf(value){value}, .{ .whitespace = .indent_2 });

    // Keep the indentation of a nested value while dropping the array delimiters.
    return nested["[\n  ".len .. nested.len - "\n]".len];
}

fn bindingRows(comptime Rows: type, allocator: std.mem.Allocator, inputs: []const Conditions.Input) std.mem.Allocator.Error!Rows {
    const Row = std.meta.Child(std.meta.Elem(Rows));
    const values = try allocator.alloc(Row, inputs.len);
    const pointers = try allocator.alloc(*const Row, inputs.len);

    for (inputs, values, pointers) |input, *row, *pointer| {
        row.* = .{
            .symbol = input.symbol,
            .path = input.path,
            .type_id = @backingInt(input.type_id),
        };

        pointer.* = row;
    }

    return pointers;
}
