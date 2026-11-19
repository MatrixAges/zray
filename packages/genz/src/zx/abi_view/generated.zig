const std = @import("std");
const zx = @import("zx");
const printer = @import("../../printer/module.zig");
const Alias = @import("../abi_view.zig").Alias;
const generated = @import("generated_abi_view");

pub fn render(allocator: std.mem.Allocator, type_names: []const []const u8, aliases: []const Alias, imported: bool) std.mem.Allocator.Error![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);

    defer arena.deinit();

    const temporary = arena.allocator();
    const borrowed = try zx.columns.pointers(@FieldType(Input, "aliases"), temporary, aliases);

    return print(allocator, temporary, type_names, borrowed, imported);
}

const Input = std.meta.Child(generated.Input);

pub fn renderBorrowed(allocator: std.mem.Allocator, type_names: []const []const u8, aliases: anytype, imported: bool) std.mem.Allocator.Error![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);

    defer arena.deinit();

    return print(allocator, arena.allocator(), type_names, zx.columns.slice(@FieldType(Input, "aliases"), aliases), imported);
}

fn print(allocator: std.mem.Allocator, temporary: std.mem.Allocator, type_names: []const []const u8, aliases: @FieldType(Input, "aliases"), imported: bool) std.mem.Allocator.Error![]u8 {
    const input: Input = .{ .names = type_names, .aliases = aliases, .imported = imported };

    const output = generated.executeIn(temporary, &input) catch |err| switch (err) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => return error.OutOfMemory,
        else => unreachable,
    };

    if (!output.valid) return error.OutOfMemory;

    return printer.render(allocator, temporary, std.meta.Child(generated.Output), output);
}
