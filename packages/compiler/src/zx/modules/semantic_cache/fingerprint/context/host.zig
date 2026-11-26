const std = @import("std");
const zx = @import("zx");
const Context = @import("../../../../analysis/analyze.zig").Context;
const columns = zx.memory;

pub fn digest(allocator: std.mem.Allocator, context: Context) std.mem.Allocator.Error![32]u8 {
    if (comptime !@import("parser_options").generated_parser) {
        const encoded = try std.json.Stringify.valueAlloc(allocator, context, .{});

        defer allocator.free(encoded);

        var result: [32]u8 = undefined;

        zx.Sha256.hash(encoded, &result, .{});

        return result;
    }

    var arena = std.heap.ArenaAllocator.init(allocator);

    defer arena.deinit();

    const entry = @import("generated_semantic_context_encode");
    const Input = std.meta.Child(entry.Input);
    const Origins = std.meta.Child(@FieldType(Input, "origins"));
    const Bindings = std.meta.Child(@FieldType(Origins, "bindings"));
    const types = zx.ir.TypeTable.borrow(std.meta.Child(@FieldType(Input, "types")), context.types);
    const modules = zx.columns.columns(std.meta.Child(@FieldType(Input, "native_modules")), context.native_modules);
    const bindings = @TypeOf(context.nominal_types).borrow(Bindings, context.nominal_types);
    const origins: Origins = .{ .bindings = &bindings, .names = context.nominal_types.names };
    const stores = context.stores;

    const input: Input = .{
        .types = &types,
        .origins = &origins,
        .native_modules = &modules,
        .stores = &.{
            .handle = @ptrCast(&columns.borrowTextColumn("handle", stores)),
            .path = @ptrCast(&columns.borrowTextColumn("path", stores)),
            .type_name = @ptrCast(&columns.borrowReadColumn(?[]const u8, "type_name", stores)),
            .type_id = @ptrCast(&columns.borrowOptionalU32Column("type_id", stores)),
            .readable = @ptrCast(&columns.borrowReadColumn(bool, "readable", stores)),
            .writable = @ptrCast(&columns.borrowReadColumn(bool, "writable", stores)),
            .count = stores.len,
        },
    };

    const encoded = entry.executeIn(arena.allocator(), &input) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };

    std.debug.assert(encoded.len == 32);

    return encoded[0..32].*;
}
