const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Nodes = @import("../../../artifact/nodes.zig");
const surface = @import("../../../artifact/surface.zig");
const names = @import("../../../../ir/canonical/validation/names/view.zig");
const remap = @import("../../../artifact/nodes/remap.zig");
const Error = @import("../../program.zig").Error;
const generated = @import("generated_source_link_declarations");
const Input = std.meta.Child(generated.Input);
const Mapping = std.meta.Child(@FieldType(Input, "types"));
const ConstantTarget = std.meta.Child(@typeInfo(@FieldType(Input, "constant_target")).optional.child);

pub fn publish(nodes: *const Nodes, program: *const ir.Program, prefix: usize) Error!struct { []const ir.Export, []const ir.Constant } {
    if (program.exports.len == 0 and program.constant_exports.len == 0) return .{ &.{}, &.{} };

    const allocator = nodes.allocator;
    const types = remap.typeMapping(Mapping, nodes.types);
    const export_rows = names.borrow(program.exports);
    const export_types = zx.memory.borrowReadColumn(ir.TypeId, "type_id", program.exports);
    const constant_rows = surface.ConstantRows.borrow(program.constant_exports);
    var written: [1]u64 = .{0};
    const progress: []u64 = &written;

    var request: Input = .{
        .prefix = prefix,
        .types = &types,
        .exports = &names.view(std.meta.Child(@FieldType(Input, "exports")), &export_rows),
        .export_types = @ptrCast(&export_types),
        .export_target = null,
        .export_progress = @ptrCast(&progress),
        .exports_done = false,
        .constants = &constant_rows.view(std.meta.Child(@FieldType(Input, "constants")), program.constant_exports.len),
        .constant_target = null,
    };

    var owned_exports: []ir.Export = &.{};
    var owned_constants: []ir.Constant = &.{};
    var export_target: []zx.memory.NamedId = undefined;
    var constant_columns: surface.ConstantTarget = undefined;
    var constant_target: ConstantTarget = undefined;

    errdefer {
        for (owned_exports[0..@intCast(written[0])]) |item| allocator.free(item.name);

        allocator.free(owned_exports);
        allocator.free(owned_constants);
    }

    while (true) {
        const storage = zx.columns.invoke(generated.executeValue, allocator, @as(*const Input, &request)) catch |err| return switch (@as(anyerror, err)) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.InvalidModule,
        };

        switch (storage) {
            .Types => {
                owned_exports = try allocator.alloc(ir.Export, program.exports.len);
                export_target = zx.memory.borrowNamedRows("type_id", owned_exports);
                request.export_target = @ptrCast(&export_target);
            },
            .Constants => {
                owned_constants = try allocator.alloc(ir.Constant, program.constant_exports.len);
                constant_columns = surface.ConstantTarget.borrow(owned_constants);
                constant_target = constant_columns.view(ConstantTarget);
                request.constant_target = &constant_target;
                request.exports_done = true;
            },
            .None => return .{
                if (owned_exports.len == 0) program.exports else owned_exports,
                if (owned_constants.len == 0) program.constant_exports else owned_constants,
            },
        }
    }
}
