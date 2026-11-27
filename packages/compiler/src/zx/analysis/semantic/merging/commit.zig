const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Origins = @import("nominal_data");
const View = @import("publication/view.zig");
const Options = View.Options;
const Merge = @import("generated_type_merge");
const MergeInput = std.meta.Child(Merge.Input);
pub const Preparation = std.meta.Child(@FieldType(MergeInput, "preparation"));
pub const Error = std.mem.Allocator.Error || error{InvalidModule};

const Registration = struct {
    temporary: std.mem.Allocator,
    preparation: *const Preparation,
    mapping_allocator: std.mem.Allocator,
};

const RegistrationResult = struct {
    status: @FieldType(std.meta.Child(Merge.Output), "status"),
    mapping: []const ir.TypeId = &.{},
};

pub fn appendTypes(allocator: std.mem.Allocator, target: *ir.TypeStorage, delta: anytype) std.mem.Allocator.Error!void {
    try append(allocator, target, null, delta, @as(Origins.Table, .{}));
}

pub fn append(allocator: std.mem.Allocator, target: *ir.TypeStorage, origins: ?*Origins.Storage, delta: anytype, bindings: anytype) std.mem.Allocator.Error!void {
    try appendWithPayload(allocator, allocator, target, origins, delta, bindings);
}

pub fn retainSuffix(allocator: std.mem.Allocator, target: *ir.TypeStorage, origins: *Origins.Storage, base_labels: *const []const []const u8, delta: anytype, bindings: anytype) std.mem.Allocator.Error!void {
    try write(.{
        .allocator = allocator,
        .payload = allocator,
        .types = target,
        .origins = origins,
        .base_labels = base_labels,
    }, zx.columns.view(ir.TypeTable, delta), bindings);
}

pub fn appendWithPayload(allocator: std.mem.Allocator, payload: std.mem.Allocator, target: *ir.TypeStorage, origins: ?*Origins.Storage, delta: anytype, bindings: anytype) std.mem.Allocator.Error!void {
    const base = View.offsets(target);

    try write(.{
        .allocator = allocator,
        .payload = payload,
        .types = target,
        .origins = origins,
        .offsets = &base,
    }, zx.columns.view(ir.TypeTable, delta), bindings);
}

pub fn appendConstructed(allocator: std.mem.Allocator, target: *ir.TypeStorage, table: ir.TypeTable, owns_names: bool) std.mem.Allocator.Error!void {
    try write(.{
        .allocator = allocator,
        .payload = allocator,
        .types = target,
        .origins = null,
        .text_mode = if (owns_names) .OwnNames else .Borrow,
    }, table, @as(Origins.Table, .{}));
}

pub fn snapshot(allocator: std.mem.Allocator, table: ir.TypeTable, comptime own_text: bool) std.mem.Allocator.Error!ir.TypeStorage {
    var target: ir.TypeStorage = .{};

    if (table.count() == 0) return target;

    errdefer target.deinit(allocator);

    try write(.{
        .allocator = allocator,
        .payload = allocator,
        .types = &target,
        .origins = null,
        .text_mode = if (own_text) .Own else .Borrow,
        .precise = true,
    }, table, @as(Origins.Table, .{}));

    return target;
}

pub fn register(allocator: std.mem.Allocator, target: *ir.TypeStorage, origins: *Origins.Storage, registration: Registration) Error!RegistrationResult {
    const base = View.offsets(target);
    var view: View = undefined;

    view.init(.{
        .allocator = allocator,
        .payload = allocator,
        .types = target,
        .origins = origins,
        .offsets = &base,
    });

    const input: MergeInput = .{ .preparation = registration.preparation, .publication = &view.target };

    const result = Merge.executeIn(registration.temporary, &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.Overflow, error.IntegerOverflow => return error.OutOfMemory,
        else => return error.InvalidModule,
    };

    const plan = result.publication orelse return .{ .status = result.status };
    const mapping = try registration.mapping_allocator.dupe(u32, result.mapping);

    errdefer registration.mapping_allocator.free(mapping);

    try view.commit(plan);

    return .{ .status = result.status, .mapping = @ptrCast(mapping) };
}

pub fn write(options: Options, table: ir.TypeTable, bindings: anytype) std.mem.Allocator.Error!void {
    var scratch = std.heap.ArenaAllocator.init(options.allocator);

    defer scratch.deinit();

    var view: View = undefined;

    view.init(options);

    var pending = try view.prepare(scratch.allocator(), table, bindings);

    pending.publish();
}
