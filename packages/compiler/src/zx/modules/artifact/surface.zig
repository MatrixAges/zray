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
const memory = zx.memory;
const ConstantRows = @import("../../analysis/constants/columns.zig").Rows;
const ConstantInput = std.meta.Child(constants.Input);
pub const Mapping = std.meta.Child(@FieldType(ConstantInput, "types"));

pub const Surface = struct {
    exports: []const ir.Export = &.{},
    constant_exports: []const ir.Constant = &.{},
    constant_imports: []const ir.Constant = &.{},
    type_imports: []const ir.Export = &.{},
    function_imports: []const Binding = &.{},
    members: []const Binding = &.{},
};

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
        .source = &rows.view(std.meta.Child(@FieldType(ConstantInput, "source"))),
        .target = &target.view(std.meta.Child(@FieldType(ConstantInput, "target"))),
        .types = types,
    };

    zx.columns.invoke(constants.executeValue, allocator, &input) catch |err| return failure(err);

    return result;
}

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

pub fn constantOutput(comptime Target: type) type {
    return memory.RowOutput(ir.Constant, Target, .{ .names = &.{"name"}, .types = &.{"type_id"}, .values = &.{"value"} });
}

pub fn Publication(comptime Input: type) type {
    const Exports = std.meta.Child(@FieldType(Input, "exports"));
    const Constants = std.meta.Child(@FieldType(Input, "constants"));
    const Target = std.meta.Child(@FieldType(Input, "constant_target"));

    return struct {
        const Self = @This();
        export_rows: names.Rows,
        export_source: Exports,
        export_target: []memory.NamedId,
        progress: []u64,
        written: [1]u64,
        constant_rows: ConstantRows,
        constant_source: Constants,
        constant_output: constantOutput(Target),
        mapping: std.meta.Child(@FieldType(Input, "types")),
        input: Input,
        pub fn init(self: *Self, export_rows: []const ir.Export, constant_rows: []const ir.Constant, types: Nodes.TypeMap) void {
            self.export_rows = names.borrow(export_rows);
            self.export_source = names.view(Exports, &self.export_rows);
            self.export_target = &.{};
            self.written = .{0};
            self.progress = &self.written;
            self.constant_rows = ConstantRows.borrow(constant_rows);
            self.constant_source = self.constant_rows.view(Constants);

            self.constant_output.init();

            self.mapping = remap.typeMapping(@TypeOf(self.mapping), types);

            self.input = .{
                .types = &self.mapping,
                .exports = &self.export_source,
                .export_target = @ptrCast(&self.export_target),
                .export_progress = @ptrCast(&self.progress),
                .constants = &self.constant_source,
                .constant_target = &self.constant_output.view,
                .constant_storage = @ptrCast(&self.constant_output.buffer),
            };
        }
        pub fn release(self: *const Self, allocator: std.mem.Allocator) void {
            for (self.export_target[0..@intCast(self.written[0])]) |item| allocator.free(item.name);

            allocator.free(self.export_target);
            allocator.free(self.constant_output.rows());
        }

        pub fn exports(self: *const Self) []const ir.Export {
            return @ptrCast(self.export_target);
        }
        pub fn constants(self: *const Self) []const ir.Constant {
            return self.constant_output.rows();
        }
    };
}

pub fn BindingPublication(comptime Input: type) type {
    const Source = std.meta.Child(@FieldType(Input, "source"));
    const Target = std.meta.Child(@FieldType(Input, "target"));
    const Map = std.meta.Child(@FieldType(Input, "types"));

    return struct {
        const Self = @This();
        source: Source,
        names: memory.TextColumn,
        namespaces: memory.ReadColumn,
        ports: Binding.Readable,
        output: memory.RowOutput(Binding, Target, .{
            .name = &.{"name"},
            .namespace = &.{"namespace"},
            .id = &.{"id"},
            .input_type = &.{"input_type"},
            .output_type = &.{"output_type"},
            .intrinsic = &.{"intrinsic"},
        }),
        types: Map,
        functions: Map,
        input: Input,
        pub fn init(self: *Self, source: []const Binding, nodes: *const Nodes) void {
            self.names = memory.borrowTextColumn("name", source);
            self.namespaces = memory.borrowReadColumn(?[]const u8, "namespace", source);
            self.ports = Binding.Readable.borrowRows(source);
            self.types = remap.typeMapping(Map, nodes.types);
            self.functions = remap.idMapping(Map, nodes.functions);

            self.output.init();

            self.source = .{
                .name = @ptrCast(&self.names),
                .namespace = @ptrCast(&self.namespaces),
                .id = @ptrCast(&self.ports.id),
                .input_type = @ptrCast(&self.ports.input_type),
                .output_type = @ptrCast(&self.ports.output_type),
                .intrinsic = @ptrCast(&self.ports.intrinsic),
                .count = source.len,
            };

            self.input = .{
                .source = &self.source,
                .target = &self.output.view,
                .storage = @ptrCast(&self.output.buffer),
                .types = &self.types,
                .functions = &self.functions,
            };
        }
    };
}

fn failure(err: anyerror) Error {
    return if (err == error.OutOfMemory) error.OutOfMemory else error.InvalidModule;
}
