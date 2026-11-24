const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const memory = zx.memory;
const model = @import("../../compiled.zig");
const Input = @import("input.zig");
const Layout = @import("installation.zig").Layout;
const Request = std.meta.Child(@typeInfo(@FieldType(Layout, "interface")).optional.child);
const Targets = std.meta.Child(@FieldType(Request, "targets"));

pub const Interface = struct {
    exports: []const model.Export = &.{},
    initializers: []const model.StoreInitializer = &.{},
};

pub const View = struct {
    exports: memory.RowOutput(model.Export, Field("exports"), .{
        .names = &.{"name"},
        .paths = &.{"path"},
        .functions = &.{"function"},
        .types = &.{"types"},
        .members = &.{"members"},
        .constants = &.{"constants"},
    }),
    types: memory.RowOutput(ir.Export, Field("types"), .{ .names = &.{"name"}, .ids = &.{"type_id"} }),
    members: memory.RowOutput(@import("../../function_import.zig"), Field("members"), .{
        .names = &.{"name"},
        .namespaces = &.{"namespace"},
        .ids = &.{"id"},
        .inputs = &.{"input_type"},
        .outputs = &.{"output_type"},
        .intrinsics = &.{"intrinsic"},
    }),
    constants: memory.RowOutput(ir.Constant, Field("constants"), .{ .names = &.{"name"}, .types = &.{"type_id"}, .values = &.{"value"} }),
    initializers: memory.RowOutput(model.StoreInitializer, Field("initializers"), .{ .identities = &.{"identity"}, .versions = &.{"schema_version"}, .functions = &.{"function"} }),
    buffers: std.meta.Child(@FieldType(Request, "buffers")),
    targets: Targets,
    request: Request,
    pub fn init(self: *View, input: *const Input, instance: []const u8, first: usize, initializer_tail: ?[]model.StoreInitializer) void {
        inline for (@typeInfo(Targets).@"struct".field_names) |name| {
            const rows = &@field(self, name);

            rows.init();
            @field(self.buffers, name) = @ptrCast(&rows.buffer);
            @field(self.targets, name) = &rows.view;
        }

        if (initializer_tail) |rows| self.initializers.bind(rows);

        self.request = .{
            .exports = zx.columns.pointer(@FieldType(Request, "exports"), &input.graph.exports.input),
            .initializers = zx.columns.pointer(@FieldType(Request, "initializers"), &input.graph.initializers),
            .first = first,
            .instance = instance,
            .buffers = &self.buffers,
            .targets = &self.targets,
        };
    }

    pub fn result(self: *const View) Interface {
        return .{ .exports = self.exports.rows(), .initializers = self.initializers.rows() };
    }
};

fn Field(comptime name: []const u8) type {
    return std.meta.Child(@FieldType(Targets, name));
}
