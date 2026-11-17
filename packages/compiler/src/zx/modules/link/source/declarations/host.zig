const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Nodes = @import("../../../artifact/nodes.zig");
const ConstantRows = @import("../../../../analysis/constants/columns.zig").Rows;
const surface = @import("../../../artifact/surface.zig");
const names = @import("../../../../ir/canonical/validation/names/view.zig");
const remap = @import("../../../artifact/nodes/remap.zig");
const Error = @import("../../program.zig").Error;
const generated = @import("generated_source_link_declarations");
const Input = std.meta.Child(generated.Input);
const Mapping = std.meta.Child(@FieldType(Input, "types"));
const ConstantTarget = std.meta.Child(@FieldType(Input, "constant_target"));

pub fn publish(nodes: *const Nodes, program: *const ir.Program, prefix: usize) Error!struct { []const ir.Export, []const ir.Constant } {
    if (program.exports.len == 0 and program.constant_exports.len == 0) return .{ &.{}, &.{} };

    const allocator = nodes.allocator;
    const types = remap.typeMapping(Mapping, nodes.types);
    const export_rows = names.borrow(program.exports);
    const export_types = zx.memory.borrowReadColumn(ir.TypeId, "type_id", program.exports);
    const constant_rows = ConstantRows.borrow(program.constant_exports);
    var written: [1]u64 = .{0};
    const progress: []u64 = &written;
    const empty: []ir.Export = &.{};
    var owned_exports = zx.memory.borrowNamedRows("type_id", empty);
    var constant_output: surface.constantOutput(ConstantTarget) = undefined;

    constant_output.init();

    const request: Input = .{
        .prefix = prefix,
        .types = &types,
        .exports = &names.view(std.meta.Child(@FieldType(Input, "exports")), &export_rows),
        .export_types = @ptrCast(&export_types),
        .export_target = @ptrCast(&owned_exports),
        .export_progress = @ptrCast(&progress),
        .constants = &constant_rows.view(std.meta.Child(@FieldType(Input, "constants"))),
        .constant_target = &constant_output.view,
        .constant_storage = @ptrCast(&constant_output.buffer),
    };

    errdefer {
        for (owned_exports[0..@intCast(written[0])]) |item| allocator.free(item.name);

        allocator.free(owned_exports);
        allocator.free(constant_output.rows());
    }

    zx.columns.invoke(generated.executeValue, allocator, &request) catch |err| return switch (@as(anyerror, err)) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidModule,
    };

    const exported: []const ir.Export = @ptrCast(owned_exports);
    const constants = constant_output.rows();

    return .{
        if (exported.len == 0) program.exports else exported,
        if (constants.len == 0) program.constant_exports else constants,
    };
}
