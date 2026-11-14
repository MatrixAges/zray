const std = @import("std");
const ir = @import("zx").ir;
const Options = @import("../../expression.zig").Options;
const Output = std.meta.Child(@import("generated_expression_analysis").Output);
const body_publication = @import("../../publication/host.zig");
const type_table = @import("../../type_table.zig");
const publication = @import("../../semantic/merging/commit.zig");

pub fn apply(allocator: std.mem.Allocator, output: *const Output, options: Options, file_name: []const u8) std.mem.Allocator.Error!ir.Program {
    const body = try body_publication.body(allocator, output.body);

    return .{
        .file_name = try allocator.dupe(u8, file_name),
        .types = try extended(allocator, output, options),
        .native_modules = try @import("../../../modules/native_context.zig").copy(allocator, options.native_modules),
        .input_type = @fromBackingInt(output.input_type),
        .output_type = @fromBackingInt(output.output_type),
        .output_ownership = switch (output.output_ownership) {
            .Copy => .copy,
            .Borrowed => .borrowed,
            .Owned => .owned,
        },
        .symbols = body.symbols,
        .expressions = body.expressions,
        .body = body.control,
        .stores = body.stores,
    };
}

pub fn expression(allocator: std.mem.Allocator, output: *const Output, options: Options) std.mem.Allocator.Error!@import("../../expression.zig").Expression {
    const types = try extended(allocator, output, options);
    const values = try body_publication.values(allocator, output.body);

    return .{
        .types = types,
        .symbols = values.symbols,
        .expressions = values.expressions,
        .value = @fromBackingInt(output.value),
    };
}

/// The table of `options` with the types the expression added: in the storage the caller lends, or in a copy.
fn extended(allocator: std.mem.Allocator, output: *const Output, options: Options) std.mem.Allocator.Error!ir.TypeTable {
    var types = if (options.type_storage) |storage| storage.* else if (options.borrow_types) try type_table.columns(allocator, options.types) else try type_table.storage(allocator, options.types);

    defer if (options.type_storage) |storage| {
        storage.* = types;
    };

    const backing = options.type_allocator orelse allocator;

    try publication.appendTypes(backing, &types, output.type_delta.*);

    return types.view();
}
