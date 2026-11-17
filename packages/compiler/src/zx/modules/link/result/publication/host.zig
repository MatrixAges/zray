const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Nodes = @import("../../../artifact/nodes.zig");
const Model = @import("../../../artifact/model.zig");
const names = @import("../../../../ir/canonical/validation/names/view.zig");
const ConstantRows = @import("../../../../analysis/constants/columns.zig").Rows;
const constantOutput = @import("../../../artifact/surface.zig").constantOutput;
const remap = @import("../../../artifact/nodes/remap.zig");
const program = @import("../host.zig");
const rule = @import("generated_artifact_program_publication");
const Input = std.meta.Child(rule.Input);
const Store = std.meta.Child(@FieldType(Input, "store_source"));
const Forward = std.meta.Child(@typeInfo(@FieldType(Input, "forward")).optional.child);
const Symbols = std.meta.Child(@FieldType(Forward, "symbols"));
const Constants = std.meta.Child(@FieldType(Input, "constant_target"));

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
        const entry = function.?;

        try functions.reserve(allocator, 1);

        functions.appendOwnedAssumeCapacity(entry.body, entry.descriptors.?);

        symbols = zx.columns.columns(Symbols, body.?.symbols);

        forward = .{
            .symbols = &symbols,
            .input_type = @backingInt(body.?.input_type),
            .output_type = @backingInt(body.?.output_type),
            .function_id = @backingInt(id),
        };
    }

    const empty: []ir.Export = &.{};
    var exports = zx.memory.borrowNamedRows("type_id", empty);
    var constant_output: constantOutput(Constants) = undefined;

    constant_output.init();

    const request: Input = .{
        .store_source = &source_stores,
        .exports = &names.view(std.meta.Child(@FieldType(Input, "exports")), &export_rows),
        .export_target = @ptrCast(&exports),
        .export_progress = @ptrCast(&progress),
        .constants = &constants.view(std.meta.Child(@FieldType(Input, "constants"))),
        .constant_target = &constant_output.view,
        .constant_storage = @ptrCast(&constant_output.buffer),
        .types = &types,
        .path = module.path,
        .forward = if (recursive != null) &forward else null,
    };

    errdefer {
        for (exports[0..@intCast(written[0])]) |value| allocator.free(value.name);

        allocator.free(exports);
        allocator.free(constant_output.rows());
    }

    const outcome = zx.columns.invoke(rule.executeValue, allocator, &request) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.Overflow, error.IntegerOverflow => return error.OutOfMemory,
        else => return error.InvalidModule,
    };

    const published = outcome orelse return error.InvalidModule;
    var linked = tables;
    linked.functions = functions.view();
    const stores = zx.columns.view(ir.StoreTable, published.stores);
    const exported: []const ir.Export = @ptrCast(exports);
    const owned_constants = constant_output.rows();
    var assembled = program.program(published.path, body, linked, stores, exported, owned_constants);

    if (published.wrapper) |wrapper| try @import("../../../forward_entry/host.zig").install(allocator, &assembled, wrapper);
    if (try @import("../../../../ir/validate.zig").validate(temporary, assembled) != null) return error.InvalidIr;

    return assembled;
}
