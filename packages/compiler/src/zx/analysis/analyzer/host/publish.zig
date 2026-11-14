const zx = @import("zx");
const ir = zx.ir;
const Context = @import("context.zig");
const publication = @import("../../publication/host.zig");
const interface = @import("../../publication/interface.zig");
const model = @import("model.zig");

pub fn apply(analyzer: *Context, output: *const model.Output, file_name: []const u8) zx.Error!ir.Program {
    const allocator = analyzer.allocator;

    if (analyzer.mode != .project) {
        const type_table = @import("../../type_table.zig");

        // A resolved body's base table outlives its program, so the program borrows its names, as `analyze` does.
        analyzer.types.* = try if (analyzer.mode == .resolved) type_table.columns(allocator, analyzer.base_types) else type_table.storage(allocator, analyzer.base_types);

        try analyzer.origins.copyValidated(analyzer.types.view(), analyzer.base_origins);
    }

    try @import("../../semantic/merging/commit.zig").append(allocator, analyzer.types, &analyzer.origins.items, output.type_delta.*, output.nominal_delta.*);

    const body = try publication.body(allocator, output.body);
    const exports = try interface.types(allocator, output.export_names, output.export_types);

    return .{
        .file_name = try allocator.dupe(u8, file_name),
        .types = analyzer.types.view(),
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
        .contracts = try publication.contracts(allocator, output.contracts),
        .exports = exports,
        .constant_exports = try interface.constants(allocator, output.constant_scope, output.constant_first),
        .type_only = output.type_only,
    };
}
