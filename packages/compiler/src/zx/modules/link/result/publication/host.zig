const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Nodes = @import("../../../artifact/nodes.zig");
const Model = @import("../../../artifact/model.zig");
const names = @import("../../../../ir/canonical/validation/names/view.zig");
const ConstantRows = @import("../../../../analysis/constants/columns.zig").Rows;
const ConstantTarget = @import("../../../artifact/surface.zig").ConstantTarget;
const remap = @import("../../../artifact/nodes/remap.zig");
const program = @import("../host.zig");
const rule = @import("generated_artifact_program_publication");
const Input = std.meta.Child(rule.Input);
const Store = std.meta.Child(@FieldType(Input, "store_source"));
const Forward = std.meta.Child(@typeInfo(@FieldType(Input, "forward")).optional.child);
const Symbols = std.meta.Child(@FieldType(Forward, "symbols"));
const Constants = std.meta.Child(@typeInfo(@FieldType(Input, "constant_target")).optional.child);

pub fn finish(allocator: std.mem.Allocator, temporary: std.mem.Allocator, module: *const Model.Module, function: ?*const Nodes.FunctionEntry, tables: program.Tables, functions: *ir.FunctionStorage, mapping: []const ir.TypeId) Model.Error!ir.Program {
    const source_stores = zx.columns.columns(Store, module.stores);
    const types = remap.typeMapping(std.meta.Child(@FieldType(Input, "types")), .{ .mapped = mapping });
    const export_rows = names.borrow(module.exports);
    const constants = ConstantRows.borrow(module.constant_exports);
    var written: [1]u64 = .{0};
    const progress: []u64 = &written;
    const body = if (function) |found| &found.body else null;
    const recursive = if (function) |found| found.recursive else null;
    var symbols: Symbols = undefined;
    var forward: Forward = undefined;

    if (recursive) |id| {
        symbols = zx.columns.columns(Symbols, body.?.symbols);

        forward = .{
            .symbols = &symbols,
            .input_type = @backingInt(body.?.input_type),
            .output_type = @backingInt(body.?.output_type),
            .function_id = @backingInt(id),
        };
    }

    var request: Input = .{
        .store_source = &source_stores,
        .stores = null,
        .recursive_saved = false,
        .exports = &names.view(std.meta.Child(@FieldType(Input, "exports")), &export_rows),
        .export_target = null,
        .export_progress = @ptrCast(&progress),
        .exports_done = false,
        .constants = &constants.view(std.meta.Child(@FieldType(Input, "constants"))),
        .constant_target = null,
        .types = &types,
        .path = module.path,
        .forward = if (recursive != null) &forward else null,
    };

    var retained_stores: Store = undefined;
    var exports: []ir.Export = &.{};
    var owned_constants: []ir.Constant = &.{};
    var target_exports: []zx.memory.NamedId = undefined;
    var target_columns: ConstantTarget = undefined;
    var target_constants: Constants = undefined;

    errdefer {
        for (exports[0..@intCast(written[0])]) |value| allocator.free(value.name);

        allocator.free(exports);
        allocator.free(owned_constants);
    }

    while (true) {
        const published = zx.columns.invoke(rule.executeValue, allocator, @as(*const Input, &request)) catch |err| switch (@as(anyerror, err)) {
            error.OutOfMemory, error.Overflow, error.IntegerOverflow => return error.OutOfMemory,
            else => return error.InvalidModule,
        };

        if (request.stores == null) {
            if (published.stores) |stores| {
                retained_stores = zx.columns.view(Store, stores);
                request.stores = &retained_stores;
            }
        }

        switch (published.stage) {
            .Invalid => return error.InvalidModule,
            .Recursive => {
                const entry = function.?;

                try functions.reserve(allocator, 1);

                functions.appendOwnedAssumeCapacity(entry.body, entry.descriptors.?);

                request.recursive_saved = true;
            },
            .Exports => {
                exports = try allocator.alloc(ir.Export, module.exports.len);
                target_exports = zx.memory.borrowNamedRows("type_id", exports);
                request.export_target = @ptrCast(&target_exports);
            },
            .Constants => {
                owned_constants = try allocator.alloc(ir.Constant, module.constant_exports.len);
                target_columns = ConstantTarget.borrow(owned_constants);
                target_constants = target_columns.view(Constants);
                request.constant_target = &target_constants;
                request.exports_done = true;
            },
            .Complete => {
                var linked = tables;
                linked.functions = functions.view();
                const stores = zx.columns.view(ir.StoreTable, published.stores.?);
                var assembled = program.program(published.path.?, body, linked, stores, exports, owned_constants);

                if (published.wrapper) |wrapper| try @import("../../../forward_entry/host.zig").install(allocator, &assembled, wrapper);
                if (try @import("../../../../ir/validate.zig").validate(temporary, assembled) != null) return error.InvalidIr;

                return assembled;
            },
        }
    }
}
