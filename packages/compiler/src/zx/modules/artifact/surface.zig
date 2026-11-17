const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Binding = @import("../function_import.zig");
const Nodes = @import("nodes.zig");
const remap = @import("nodes/remap.zig");
const Error = @import("model.zig").Error;
const names = @import("../../ir/canonical/validation/names/view.zig");
const constants = @import("generated_artifact_surface_constants");
const exports = @import("generated_artifact_surface_exports");
const bindings = @import("generated_artifact_surface_binding");
const ConstantInput = std.meta.Child(constants.Input);
pub const Mapping = std.meta.Child(@FieldType(ConstantInput, "types"));
const BindingInput = std.meta.Child(bindings.Input);
const BindingMapping = std.meta.Child(@FieldType(BindingInput, "types"));

const Surface = struct {
    exports: []const ir.Export = &.{},
    constant_exports: []const ir.Constant = &.{},
    constant_imports: []const ir.Constant = &.{},
    type_imports: []const ir.Export = &.{},
    function_imports: []const Binding = &.{},
    members: []const Binding = &.{},
};

pub fn copy(nodes: *const Nodes, source: Surface) Error!Surface {
    const allocator = nodes.allocator;
    const types = remap.typeMapping(Mapping, nodes.types);
    const binding_types = remap.typeMapping(BindingMapping, nodes.types);
    const functions = remap.idMapping(BindingMapping, nodes.functions);
    var result: Surface = .{};

    result.exports = try copyExports(allocator, source.exports, &types);
    result.constant_exports = try copyConstants(allocator, source.constant_exports, &types);
    result.constant_imports = try copyConstants(allocator, source.constant_imports, &types);
    result.type_imports = try copyExports(allocator, source.type_imports, &types);
    result.function_imports = try copyBindings(allocator, source.function_imports, &binding_types, &functions);
    result.members = try copyBindings(allocator, source.members, &binding_types, &functions);

    return result;
}

pub fn copyExports(allocator: std.mem.Allocator, source: []const ir.Export, types: *const Mapping) Error![]const ir.Export {
    if (source.len == 0) return &.{};

    const result = try allocator.alloc(ir.Export, source.len);
    const rows = names.borrow(source);
    const target = @import("zx").memory.borrowNamedRows("type_id", result);
    var written: [1]u64 = .{0};

    errdefer {
        for (result[0..@intCast(written[0])]) |item| allocator.free(item.name);

        allocator.free(result);
    }

    const Input = std.meta.Child(exports.Input);
    const view = names.view(std.meta.Child(@FieldType(Input, "source")), &rows);
    const progress: []u64 = &written;

    const input: Input = .{
        .source = &view,
        .types = zx.columns.pointer(@FieldType(Input, "types"), types),
        .target = @ptrCast(&target),
        .progress = @ptrCast(&progress),
    };

    zx.columns.invoke(exports.executeValue, allocator, &input) catch |err| return failure(err);

    return result;
}

pub fn copyConstants(allocator: std.mem.Allocator, source: []const ir.Constant, types: *const Mapping) Error![]const ir.Constant {
    if (source.len == 0) return &.{};

    const result = try allocator.alloc(ir.Constant, source.len);
    const rows = ConstantRows.borrow(source);
    const target = ConstantTarget.borrow(result);

    const input: ConstantInput = .{
        .source = &rows.view(std.meta.Child(@FieldType(ConstantInput, "source")), source.len),
        .target = &target.view(std.meta.Child(@FieldType(ConstantInput, "target"))),
        .types = types,
    };

    zx.columns.invoke(constants.executeValue, allocator, &input) catch |err| return failure(err);

    return result;
}

pub const ConstantRows = struct {
    names: zx.memory.TextColumn,
    types: zx.memory.ReadColumn,
    values: zx.memory.ReadColumn,
    pub fn borrow(source: []const ir.Constant) ConstantRows {
        return .{
            .names = zx.memory.borrowTextColumn("name", source),
            .types = zx.memory.borrowReadColumn(ir.TypeId, "type_id", source),
            .values = zx.memory.borrowReadColumn(ir.ConstantValue, "value", source),
        };
    }

    pub fn view(self: *const ConstantRows, comptime Rows: type, count: usize) Rows {
        return .{
            .names = @ptrCast(&self.names),
            .types = @ptrCast(&self.types),
            .values = @ptrCast(&self.values),
            .count = count,
        };
    }
};

pub const ConstantTarget = struct {
    names: zx.memory.WriteColumn,
    types: zx.memory.WriteColumn,
    values: zx.memory.WriteColumn,
    pub fn borrow(target: []ir.Constant) ConstantTarget {
        return .{
            .names = zx.memory.borrowWriteColumn([]const u8, "name", target),
            .types = zx.memory.borrowWriteColumn(u32, "type_id", target),
            .values = zx.memory.borrowWriteColumn(ir.ConstantValue, "value", target),
        };
    }

    pub fn view(self: *const ConstantTarget, comptime Target: type) Target {
        return .{
            .names = @ptrCast(&self.names),
            .types = @ptrCast(&self.types),
            .values = @ptrCast(&self.values),
        };
    }
};

fn copyBindings(allocator: std.mem.Allocator, source: []const Binding, types: *const BindingMapping, functions: *const BindingMapping) Error![]const Binding {
    const result = try allocator.alloc(Binding, source.len);

    for (source, result) |*item, *target| {
        const input: BindingInput = .{
            .name = item.name,
            .namespace = item.namespace,
            .id = if (item.id) |id| @backingInt(id) else null,
            .input_type = if (item.input_type) |id| @backingInt(id) else null,
            .output_type = if (item.output_type) |id| @backingInt(id) else null,
            .types = types,
            .functions = functions,
        };

        const row = zx.columns.invoke(bindings.executeValue, allocator, &input) catch |err| return failure(err);

        target.* = .{
            .name = row.name,
            .namespace = row.namespace,
            .id = if (row.id) |id| @fromBackingInt(id) else null,
            .input_type = if (row.input_type) |id| @fromBackingInt(id) else null,
            .output_type = if (row.output_type) |id| @fromBackingInt(id) else null,
            .intrinsic = item.intrinsic,
        };
    }

    return result;
}

fn failure(err: anyerror) Error {
    return if (err == error.OutOfMemory) error.OutOfMemory else error.InvalidModule;
}
