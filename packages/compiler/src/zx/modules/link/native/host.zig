const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Error = @import("../../artifact/model.zig").Error || error{ConflictingInterface};
const rule = @import("generated_native_link");
const Input = std.meta.Child(rule.Input);
const Plan = std.meta.Child(@typeInfo(@FieldType(Input, "plan")).optional.child);
const Publication = std.meta.Child(@FieldType(Input, "publication"));
const Destination = std.meta.Child(@FieldType(Publication, "destination"));
const Row = std.meta.Child(std.meta.Child(@FieldType(Destination, "shape")));
const Table = std.meta.Child(@FieldType(Publication, "source"));

pub fn link(temporary: std.mem.Allocator, allocator: std.mem.Allocator, modules: *ir.NativeModuleStorage, source: ir.NativeModuleTable, mapping: []?ir.NativeModuleId, types: []const u32) Error!void {
    return publish(temporary, allocator, modules, source, types, mapping);
}

pub fn append(temporary: std.mem.Allocator, allocator: std.mem.Allocator, modules: *ir.NativeModuleStorage, source: ir.NativeModuleTable, types: []const u32) std.mem.Allocator.Error!void {
    if (source.count() == 0) return;

    publish(temporary, allocator, modules, source, types, null) catch return error.OutOfMemory;
}

fn publish(temporary: std.mem.Allocator, allocator: std.mem.Allocator, modules: *ir.NativeModuleStorage, source: ir.NativeModuleTable, types: []const u32, mapping: ?[]?ir.NativeModuleId) Error!void {
    const base = zx.columns.columns(std.meta.Child(@FieldType(Plan, "base")), modules.view());
    const rows = zx.columns.columns(Table, source);
    const slots = zx.memory.bindColumnSet(Row, true, modules);
    const columns: zx.memory.ColumnSet = &slots;
    const target: []?ir.NativeModuleId = mapping orelse &.{};
    var ids: []u32 = &.{};

    const input: Input = .{
        .plan = if (mapping != null) &.{ .base = &base, .source = &rows, .types = types, .target = @ptrCast(&target) } else null,
        .publication = &.{
            .source = &rows,
            .mapping = types,
            .destination = &.{
                .storage = @ptrCast(&columns),
                .shape = null,
                .resource = @ptrCast(&allocator),
                .ids = @ptrCast(&ids),
            },
        },
    };

    const failure = rule.executeIn(temporary, &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.Overflow, error.IntegerOverflow => return error.OutOfMemory,
        else => return error.InvalidModule,
    };

    if (failure) |status| return switch (status) {
        .Conflict => error.ConflictingInterface,
        .Full => error.OutOfMemory,
        else => error.InvalidModule,
    };
}
