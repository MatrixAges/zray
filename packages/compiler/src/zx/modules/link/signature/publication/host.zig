const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Error = @import("../../../artifact/model.zig").Error;
const columns = @import("../../../artifact/materializing/publication/columns.zig");
const rule = @import("generated_artifact_signature_publication");
const Parameter = @typeInfo(@TypeOf(rule.executeState)).@"fn".param_types[1].?;
const Input = if (@typeInfo(Parameter) == .pointer) std.meta.Child(Parameter) else Parameter;
const Empty = std.meta.Child(@FieldType(Input, "empty"));
const Source = @FieldType(Input, "source");

pub fn append(allocator: std.mem.Allocator, storage: *ir.FunctionStorage, source: ir.SignatureTable, resolution: anytype, mapping: []?ir.FunctionId) Error!void {
    const native_id = resolution.native_id orelse return error.InvalidModule;

    try storage.reserve(allocator, 1);

    const target = columns.borrow(@FieldType(Input, "columns"), storage.reservedTail(1), true);
    const signatures = if (@typeInfo(Source) == .pointer) zx.columns.columns(std.meta.Child(Source), source) else columns.borrow(Source, source, false);

    const input: Input = .{
        .source = if (@typeInfo(Source) == .pointer) &signatures else signatures,
        .row = resolution.next,
        .ports = .{
            .input = resolution.input_type,
            .output = resolution.output_type,
            .native_module = native_id,
        },
        .empty = &.{
            .symbols = zx.columns.pointer(@FieldType(Empty, "symbols"), &ir.FunctionStorage.empty_symbols),
            .expressions = zx.columns.pointer(@FieldType(Empty, "expressions"), &ir.FunctionStorage.empty_expressions),
            .contracts = zx.columns.pointer(@FieldType(Empty, "contracts"), &ir.FunctionStorage.empty_contracts),
            .control = zx.columns.pointer(@FieldType(Empty, "control"), (ir.ControlBody{}).control),
            .stores = zx.columns.pointer(@FieldType(Empty, "stores"), &ir.FunctionStorage.empty_stores),
        },
        .columns = target,
        .mapping = @ptrCast(&mapping),
        .id = resolution.row,
    };

    const written = rule.executeState(allocator, if (@typeInfo(Parameter) == .pointer) &input else input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.Overflow, error.IntegerOverflow => return error.OutOfMemory,
        else => return error.InvalidModule,
    };

    columns.checkBorrow(target, written);
    storage.commitTail(1);
}
