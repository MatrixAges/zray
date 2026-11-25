const std = @import("std");
const zx = @import("zx");
const printer = @import("../../printer/module.zig");
const generated = @import("generated_abi_view");
const Input = std.meta.Child(generated.Input);
pub const Alias = std.meta.Child(std.meta.Child(@FieldType(Input, "aliases")));

pub fn render(allocator: std.mem.Allocator, type_names: []const []const u8, aliases: []const Alias, imported: bool) std.mem.Allocator.Error![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);

    defer arena.deinit();

    const temporary = arena.allocator();
    const borrowed = try zx.columns.pointers(@FieldType(Input, "aliases"), temporary, aliases);

    return print(allocator, temporary, type_names, borrowed, imported, null);
}

pub fn renderBorrowed(allocator: std.mem.Allocator, type_names: []const []const u8, aliases: anytype, imported: bool, canonical: ?[]const u8) std.mem.Allocator.Error![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);

    defer arena.deinit();

    return print(allocator, arena.allocator(), type_names, zx.columns.slice(@FieldType(Input, "aliases"), aliases), imported, canonical);
}

fn print(allocator: std.mem.Allocator, temporary: std.mem.Allocator, type_names: []const []const u8, aliases: @FieldType(Input, "aliases"), imported: bool, canonical: ?[]const u8) std.mem.Allocator.Error![]u8 {
    const input: Input = .{ .names = type_names, .aliases = aliases, .imported = imported };

    const output = generated.executeIn(temporary, &input) catch |err| switch (err) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => return error.OutOfMemory,
        else => unreachable,
    };

    if (!output.valid) return error.OutOfMemory;

    var writer: zx.memory.ByteWriter = .{ .allocator = allocator };

    defer writer.deinit();

    if (canonical) |types| {
        try writer.buffer.ensureUnusedCapacity(allocator, types.len + 1);
        try zx.memory.ByteWriter.appendBytes(&writer, types);
        try zx.memory.ByteWriter.appendByte(&writer, '\n');
    }

    try printer.write(&writer, temporary, std.meta.Child(generated.Output), output);

    return writer.finish();
}
