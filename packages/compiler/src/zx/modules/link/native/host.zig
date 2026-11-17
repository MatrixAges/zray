const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Error = @import("../../artifact/model.zig").Error || error{ConflictingInterface};
const rule = @import("generated_native_link");
const Input = std.meta.Child(rule.Input);
const Plan = std.meta.Child(@typeInfo(@FieldType(Input, "plan")).optional.child);
const Publication = std.meta.Child(@typeInfo(@FieldType(Input, "publish")).optional.child);
const Target = std.meta.Child(@FieldType(Publication, "target"));
const Destination = std.meta.Child(@FieldType(Target, "columns"));
const Table = std.meta.Child(@FieldType(Publication, "source"));

pub fn link(temporary: std.mem.Allocator, allocator: std.mem.Allocator, modules: *ir.NativeModuleStorage, source: ir.NativeModuleTable, mapping: []?ir.NativeModuleId, types: []const u32) Error!void {
    const base = zx.columns.columns(std.meta.Child(@FieldType(Plan, "base")), modules.view());
    const rows = zx.columns.columns(std.meta.Child(@FieldType(Plan, "source")), source);

    const input: Input = .{
        .plan = &.{ .base = &base, .source = &rows, .types = types, .target = @ptrCast(&mapping) },
        .publish = null,
    };

    const plan = zx.columns.invoke(rule.executeValue, temporary, &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.Overflow, error.IntegerOverflow => return error.OutOfMemory,
        else => return error.InvalidModule,
    };

    if (plan.failure) |status| return switch (status) {
        .Conflict => error.ConflictingInterface,
        .Full => error.OutOfMemory,
        else => error.InvalidModule,
    };

    return publish(allocator, modules, source, types, plan.additions);
}

pub fn append(allocator: std.mem.Allocator, modules: *ir.NativeModuleStorage, source: ir.NativeModuleTable, types: []const u32) std.mem.Allocator.Error!void {
    return publish(allocator, modules, source, types, null);
}

fn publish(allocator: std.mem.Allocator, modules: *ir.NativeModuleStorage, source: ir.NativeModuleTable, types: []const u32, selected: ?[]const u64) std.mem.Allocator.Error!void {
    const count = if (selected) |rows| rows.len else source.count();

    if (count == 0) return;
    try modules.reserve(allocator, count);

    const rows = zx.columns.columns(Table, source);
    var completed: [1]u64 = .{0};
    const progress: []u64 = &completed;
    var tail: Tail = undefined;

    defer modules.commitTail(@intCast(completed[0]));

    const target: Target = .{ .columns = &tail.borrow(modules, count), .progress = @ptrCast(&progress) };

    const input: Input = .{
        .plan = null,
        .publish = &.{ .source = &rows, .mapping = types, .rows = selected, .target = &target },
    };

    _ = zx.columns.invoke(rule.executeValue, allocator, &input) catch return error.OutOfMemory;
}

const Tail = struct {
    identities: []?[]const u8,
    import_names: [][]const u8,
    specifiers: [][]const u8,
    type_ids: [][]const u32,
    type_names: [][]const []const u8,
    type_namespaces: [][]const []const u8,
    fn borrow(self: *Tail, storage: *ir.NativeModuleStorage, count: usize) Destination {
        var result: Destination = undefined;

        inline for (@typeInfo(Tail).@"struct".field_names) |field| {
            @field(self, field) = @field(storage, field).unusedCapacitySlice()[0..count];
            @field(result, field) = @ptrCast(&@field(self, field));
        }

        return result;
    }
};
