const std = @import("std");
const zx = @import("zx");
const Analysis = @import("../../../analysis/analyze.zig");
const Record = @import("../../module_record.zig");
const Nodes = @import("../nodes.zig");
const model = @import("../model.zig");
const Origins = @import("../../nominal_origins.zig");
const generated = @import("generated_artifact_extract");
const Preparation = @import("run.zig");
const Materialization = @import("materialize.zig");
const Rows = @import("rows.zig");

const Frame = struct {
    record: *const Record,
    allocator: std.mem.Allocator,
    materialization: Materialization = undefined,
    rows: Rows = .{},
    pub fn commit(self: *Frame, pending: anytype) std.mem.Allocator.Error!void {
        if (pending.store_0) |entry| {
            if (entry.imported) {
                try self.materialization.imported.publishExport(self.allocator, entry);
            } else try self.materialization.exported.publishExport(self.allocator, entry);
        }

        if (pending.store_1) |entry| try self.rows.bindings(self.allocator, self.record, entry);
        if (pending.store_2) |entry| try self.rows.dependency(self.allocator, self.record.imports, entry);
    }
};

pub fn extract(allocator: std.mem.Allocator, scratch: std.mem.Allocator, analysis: *const Analysis.Result, record: Record) model.Error!model.Module {
    var preparation: Preparation = undefined;

    try preparation.bind(scratch, analysis, &record);

    var frame: Frame = .{ .record = &record, .allocator = allocator };

    var input: std.meta.Child(generated.Input) = .{
        .preparation = &preparation.input,
        .materialization = null,
        .prepared = null,
    };

    const plan = generated.executeIn(scratch, &input, &frame) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidModule,
    };

    const prepared = plan.prepared orelse return switch (plan.status) {
        .MissingOrigin => error.MissingNominalOrigin,
        else => error.InvalidModule,
    };

    const program = &analysis.value.ir;
    const body = prepared.body;

    const source = if (body.function_id) |row|
        zx.ir.FunctionView.at(&program.functions, row)

    else if (body.use_entry)
        zx.ir.FunctionView.borrow(program)
    else
        null;

    const nodes: Nodes = .{
        .allocator = allocator,
        .types = .{ .planned = prepared.plan.state.mapping },
        .functions = .{ .planned = prepared.plan.functions.mapping },
        .native_modules = .{ .planned = prepared.plan.natives.mapping },
    };

    frame.materialization.bind(&nodes, program, if (source) |*value| value else null, body.copy_entry_stores, &record);
    errdefer frame.rows.release(allocator, record.imports);
    errdefer frame.materialization.exported.release(allocator);
    errdefer frame.materialization.imported.release(allocator);

    input.materialization = &frame.materialization.input;
    input.prepared = prepared;

    const result = generated.executeIn(allocator, &input, &frame) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidModule,
    };

    const materialized = result.artifact orelse return error.InvalidModule;
    const types = zx.columns.view(zx.ir.TypeTable, materialized.table);
    const origins = zx.columns.view(Origins.Table, materialized.origins);
    const native_modules = zx.columns.view(zx.ir.NativeModuleTable, materialized.natives);
    const functions = zx.columns.view(zx.ir.SignatureTable, materialized.signatures);

    const function = if (materialized.function) |mapped|
        @import("../materializing/descriptor.zig").function(mapped)

    else
        null;

    const stores: zx.ir.StoreTable = if (materialized.stores) |value| zx.columns.view(zx.ir.StoreTable, value) else .{};
    const surface = frame.materialization.publishedSurface(frame.rows.function_imports, frame.rows.members);

    return .{
        .path = materialized.path,
        .source_digest = record.source_digest,
        .dependencies = frame.rows.dependencies,
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
