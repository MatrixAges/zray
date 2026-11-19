const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Origins = @import("nominal_data");
const rule = @import("generated_type_merge_publication");
const Input = std.meta.Child(rule.Input);
const Table = std.meta.Child(@FieldType(Input, "delta"));
const Bindings = std.meta.Child(@FieldType(Input, "origins"));
const View = @import("publication/view.zig");
const Options = View.Options;
const Merge = @import("generated_type_merge");
const MergeInput = std.meta.Child(Merge.Input);
pub const Preparation = std.meta.Child(@FieldType(MergeInput, "preparation"));
pub const Error = std.mem.Allocator.Error || error{InvalidModule};
const Operation = enum { register, publish };
const Registration = struct { temporary: std.mem.Allocator, preparation: *const Preparation };

pub fn appendTypes(allocator: std.mem.Allocator, target: *ir.TypeStorage, delta: anytype) std.mem.Allocator.Error!void {
    try append(allocator, target, null, delta, @as(Origins.Table, .{}));
}

pub fn append(allocator: std.mem.Allocator, target: *ir.TypeStorage, origins: ?*Origins.Storage, delta: anytype, bindings: anytype) std.mem.Allocator.Error!void {
    try appendWithPayload(allocator, allocator, target, origins, delta, bindings);
}

pub fn appendWithPayload(allocator: std.mem.Allocator, payload: std.mem.Allocator, target: *ir.TypeStorage, origins: ?*Origins.Storage, delta: anytype, bindings: anytype) std.mem.Allocator.Error!void {
    const base = View.offsets(target);

    try write(.publish, .{
        .allocator = allocator,
        .payload = payload,
        .types = target,
        .origins = origins,
        .offsets = &base,
    }, zx.columns.view(ir.TypeTable, delta), bindings, {});
}

pub fn appendConstructed(allocator: std.mem.Allocator, target: *ir.TypeStorage, table: ir.TypeTable, owns_names: bool) std.mem.Allocator.Error!void {
    try write(.publish, .{
        .allocator = allocator,
        .payload = allocator,
        .types = target,
        .origins = null,
        .text_mode = if (owns_names) .OwnNames else .Borrow,
    }, table, @as(Origins.Table, .{}), {});
}

pub fn snapshot(allocator: std.mem.Allocator, table: ir.TypeTable, comptime own_text: bool) std.mem.Allocator.Error!ir.TypeStorage {
    var target: ir.TypeStorage = .{};

    if (table.count() == 0) return target;

    errdefer target.deinit(allocator);

    try write(.publish, .{
        .allocator = allocator,
        .payload = allocator,
        .types = &target,
        .origins = null,
        .text_mode = if (own_text) .Own else .Borrow,
        .precise = true,
    }, table, @as(Origins.Table, .{}), {});

    return target;
}

pub fn register(allocator: std.mem.Allocator, target: *ir.TypeStorage, origins: *Origins.Storage, registration: Registration) Error!Merge.Output {
    const base = View.offsets(target);

    return write(.register, .{
        .allocator = allocator,
        .payload = allocator,
        .types = target,
        .origins = origins,
        .offsets = &base,
    }, .{}, @as(Origins.Table, .{}), registration);
}

fn write(
    comptime operation: Operation,
    options: Options,
    table: ir.TypeTable,
    bindings: anytype,
    registration: if (operation == .register) Registration else void,
) (if (operation == .register) Error!Merge.Output else std.mem.Allocator.Error!void) {
    var view: View = undefined;

    view.init(&options, table, bindings);
    errdefer view.release(&options);

    const publication = view.target;

    if (comptime operation == .register) {
        const input: MergeInput = .{ .preparation = registration.preparation, .publication = &publication };

        return Merge.executeIn(registration.temporary, &input) catch |err| switch (@as(anyerror, err)) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.InvalidModule,
        };
    }

    const types = ir.TypeTable.borrow(Table, table);

    const nominal: Bindings = .{
        .ids = bindings.ids,
        .kinds = bindings.kinds,
        .owners = bindings.owners,
        .members = bindings.members,
    };

    const input: Input = .{
        .delta = &types,
        .origins = &nominal,
        .target = publication.target,
        .nominal = publication.nominal,
        .offsets = publication.offsets,
        .base_labels = publication.base_labels,
        .text_mode = publication.text_mode,
        .progress = publication.progress,
        .destination = publication.destination,
        .payload = publication.payload,
    };

    rule.executeIn(options.payload, &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };
}
