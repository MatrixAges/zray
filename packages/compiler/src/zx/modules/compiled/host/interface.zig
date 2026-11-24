const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const memory = zx.memory;
const model = @import("../../compiled.zig");
const Input = @import("input.zig");
const Plan = std.meta.Child(@import("generated_compiled_library").Output);
const Publication = @import("function.zig").Request;
const Request = std.meta.Child(@typeInfo(@FieldType(Publication, "interface")).optional.child);
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
    selection: std.meta.Child(@typeInfo(@FieldType(Request, "selection")).optional.child),
    buffers: std.meta.Child(@FieldType(Request, "buffers")),
    targets: Targets,
    request: Request,
    pub fn init(self: *View, input: *const Input, plan: *const Plan, first: usize) void {
        inline for (@typeInfo(Targets).@"struct".field_names) |name| {
            const rows = &@field(self, name);

            rows.init();
            @field(self.buffers, name) = @ptrCast(&rows.buffer);
            @field(self.targets, name) = &rows.view;
        }

        if (plan.selection) |value| self.selection = zx.columns.view(@TypeOf(self.selection), value);

        self.request = .{
            .exports = zx.columns.pointer(@FieldType(Request, "exports"), &input.graph.exports.input),
            .initializers = zx.columns.pointer(@FieldType(Request, "initializers"), &input.graph.initializers),
            .selection = if (plan.selection != null) &self.selection else null,
            .first = first,
            .mapping = plan.functions.types,
            .instance = input.input.instance,
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
