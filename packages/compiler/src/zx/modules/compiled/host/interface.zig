const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const memory = zx.memory;
const model = @import("../../compiled.zig");
const Input = @import("input.zig");
const Plan = std.meta.Child(@import("generated_compiled_library").Output);
const generated = @import("generated_compiled_interface");
const Request = std.meta.Child(generated.Input);
const Targets = std.meta.Child(@FieldType(Request, "targets"));

pub const Interface = struct {
    exports: []const model.Export = &.{},
    initializers: []const model.StoreInitializer = &.{},
};

pub fn materialize(allocator: std.mem.Allocator, input: *const Input, plan: *const Plan, first: usize) (std.mem.Allocator.Error || error{InvalidModule})!Interface {
    if (input.exports.input.count == 0 and input.initializers.input.count == 0) return .{};

    var exports: memory.RowOutput(model.Export, Field("exports"), .{
        .names = &.{"name"},
        .paths = &.{"path"},
        .functions = &.{"function"},
        .types = &.{"types"},
        .members = &.{"members"},
        .constants = &.{"constants"},
    }) = undefined;

    var types: memory.RowOutput(ir.Export, Field("types"), .{ .names = &.{"name"}, .ids = &.{"type_id"} }) = undefined;

    var members: memory.RowOutput(@import("../../function_import.zig"), Field("members"), .{
        .names = &.{"name"},
        .namespaces = &.{"namespace"},
        .ids = &.{"id"},
        .inputs = &.{"input_type"},
        .outputs = &.{"output_type"},
        .intrinsics = &.{"intrinsic"},
    }) = undefined;

    var constants: memory.RowOutput(ir.Constant, Field("constants"), .{ .names = &.{"name"}, .types = &.{"type_id"}, .values = &.{"value"} }) = undefined;
    var initializers: memory.RowOutput(model.StoreInitializer, Field("initializers"), .{ .identities = &.{"identity"}, .versions = &.{"schema_version"}, .functions = &.{"function"} }) = undefined;

    exports.init();
    types.init();
    members.init();
    constants.init();
    initializers.init();

    const Exports = std.meta.Child(@FieldType(Request, "exports"));
    const Initializers = std.meta.Child(@FieldType(Request, "initializers"));
    const Selection = std.meta.Child(@typeInfo(@FieldType(Request, "selection")).optional.child);
    const exports_view = zx.columns.view(Exports, input.exports.input);
    const initializers_view = zx.columns.view(Initializers, input.initializers.input);
    const selection = if (plan.selection) |value| zx.columns.view(Selection, value) else null;

    const request: Request = .{
        .exports = &exports_view,
        .initializers = &initializers_view,
        .selection = if (selection) |*value| value else null,
        .first = first,
        .mapping = plan.functions.types,
        .instance = input.input.instance,
        .buffers = &.{
            .exports = @ptrCast(&exports.buffer),
            .types = @ptrCast(&types.buffer),
            .members = @ptrCast(&members.buffer),
            .constants = @ptrCast(&constants.buffer),
            .initializers = @ptrCast(&initializers.buffer),
        },
        .targets = &.{
            .exports = &exports.view,
            .types = &types.view,
            .members = &members.view,
            .constants = &constants.view,
            .initializers = &initializers.view,
        },
    };

    zx.columns.invoke(generated.executeValue, allocator, &request) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.Overflow, error.IntegerOverflow => return error.OutOfMemory,
        else => return error.InvalidModule,
    };

    return .{ .exports = exports.rows(), .initializers = initializers.rows() };
}

fn Field(comptime name: []const u8) type {
    return std.meta.Child(@FieldType(Targets, name));
}
