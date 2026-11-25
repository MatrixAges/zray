const std = @import("std");
const zx = @import("zx");
const options = @import("parser_options");
const Source = @import("../analysis/semantic/resolving/host/source.zig");
const layout = @import("../analysis/semantic/resolving/host/layout.zig");

pub fn parameters(arena: *std.heap.ArenaAllocator, view: anytype, values: anytype, reporter: *zx.Reporter) zx.Error!zx.ir.NativeType {
    const allocator = arena.allocator();

    if (comptime !options.generated_parser) return @import("seed_native_types.zig").parameters(allocator, view, values, reporter);

    const generated = @import("generated_native_names");
    const Input = std.meta.Child(generated.Input);
    var source: Source = .{};

    try source.init(allocator, view, null);

    const source_value: *const @TypeOf(source.value) = &source.value;

    const input: Input = .{
        .source = layout.borrow(@FieldType(Input, "source"), source_value),
        .parameters = layout.borrow(@FieldType(Input, "parameters"), view.storage.parameters),
        .first = values.first,
        .count = values.len,
    };

    const result = generated.execute(arena, &input) catch |err| switch (err) {
        error.OutOfMemory, error.Overflow => return error.OutOfMemory,
        else => unreachable,
    };

    if (!result.valid) return reporter.fail(.unsupported, .{ .start = 0, .end = 0 }, "native arrays of objects, tuples or enums require a named element type exported by the native module");

    const names = try allocator.alloc(?[]const u8, result.names.len);

    for (result.names, names) |source_name, *target| {
        target.* = if (source_name) |text| try allocator.dupe(u8, text) else null;
    }

    return .{ .names = names };
}
