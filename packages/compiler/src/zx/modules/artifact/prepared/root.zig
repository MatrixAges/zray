const std = @import("std");
const zx = @import("zx");
const Analysis = @import("../../../analysis/analyze.zig");
const Record = @import("../../module_record.zig");
const Nodes = @import("../nodes.zig");
const model = @import("../model.zig");
const Origins = @import("../../nominal_origins.zig");

pub fn extract(allocator: std.mem.Allocator, scratch: std.mem.Allocator, analysis: *const Analysis.Result, record: Record) model.Error!model.Module {
    const program = &analysis.value.ir;
    const prepared = try @import("run.zig").execute(scratch, analysis, record);
    const body = prepared.body;

    const source = if (body.function_id) |row|
        program.functions.at(row)

    else if (body.use_entry)
        @import("../../function_body.zig").value(program.*)
    else
        null;

    var nodes = Nodes{
        .allocator = allocator,
        .types = .{ .planned = prepared.plan.state.mapping },
        .functions = .{ .planned = prepared.plan.functions.mapping },
        .native_modules = .{ .planned = prepared.plan.natives.mapping },
    };

    const published = try @import("materialize.zig").materialize(&nodes, program, analysis.nominal_types, prepared, if (source) |*value| value else null, &record);
    const materialized = published.contents;
    const types = zx.columns.view(zx.ir.TypeTable, materialized.table);
    const origins = zx.columns.view(Origins.Table, materialized.origins);
    const native_modules = zx.columns.view(zx.ir.NativeModuleTable, materialized.natives);
    const functions = zx.columns.view(zx.ir.SignatureTable, materialized.signatures);

    const function = if (materialized.function) |mapped|
        Nodes.linkedFunction(&source.?, mapped)

    else
        null;

    const stores: zx.ir.StoreTable = if (materialized.stores) |value| zx.columns.view(zx.ir.StoreTable, value) else .{};
    const surface = published.surface;

    return .{
        .path = materialized.path,
        .source_digest = record.source_digest,
        .dependencies = published.dependencies,
        .types = types,
        .nominal_types = origins,
        .exports = surface.exports,
        .constant_exports = surface.constant_exports,
        .constant_imports = surface.constant_imports,
        .type_imports = surface.type_imports,
        .function_imports = surface.function_imports,
        .members = surface.members,
        .functions = functions,
        .native_modules = native_modules,
        .function = function,
        .stores = stores,
    };
}
