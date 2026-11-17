const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Origins = @import("nominal_data");
const generated = @import("generated_type_merge");
const Input = std.meta.Child(generated.Input);
const Data = std.meta.Child(@FieldType(Input, "request"));
const Table = std.meta.Child(@FieldType(Data, "source"));
const Bindings = std.meta.Child(@FieldType(Data, "origins"));
const Limits = std.meta.Child(@typeInfo(@FieldType(Input, "validation")).optional.child);
pub const Error = std.mem.Allocator.Error || error{ InvalidModule, MissingNominalOrigin, ConflictingNominalType };

pub const Request = struct {
    allocator: std.mem.Allocator,
    mapping_allocator: std.mem.Allocator,
    temporary: std.mem.Allocator,
    source: ir.TypeTable,
    origins: Origins.Table,
    items: *ir.TypeStorage,
    nominal: *Origins.Storage,
    first: usize,
    checked: bool,
    complete: bool,
};

pub fn append(request: Request) Error![]const ir.TypeId {
    var mapping: []u32 = &.{};
    var arena = std.heap.ArenaAllocator.init(request.temporary);

    defer arena.deinit();
    errdefer request.mapping_allocator.free(mapping);

    const source = ir.TypeTable.borrow(Table, request.source);
    const base = ir.TypeTable.borrow(Table, request.items.view());
    const origins = Origins.Table.borrow(Bindings, request.origins);
    const base_origins = Origins.Table.borrow(Bindings, request.nominal.view());
    const limits: Limits = .{ .maximum_count = std.math.maxInt(u32), .scalar_count = std.enums.values(ir.Scalar).len };

    const input: Input = .{
        .request = &.{
            .source = &source,
            .origins = &origins,
            .base = &base,
            .base_origins = &base_origins,
            .mapping = @ptrCast(&mapping),
            .first = request.first,
            .checked = request.checked,
        },
        .names = request.origins.names,
        .resource = @ptrCast(&request.mapping_allocator),
        .complete = request.complete,
        .validation = if (request.first == 0 or request.checked) &limits else null,
    };

    const prepared = zx.columns.invoke(generated.executeValue, arena.allocator(), &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidModule,
    };

    const result = prepared orelse return error.InvalidModule;

    try @import("merging/commit.zig").append(request.allocator, request.items, request.nominal, result.delta, result.origins);

    return switch (result.status) {
        .Ready => @ptrCast(mapping),
        .MissingOrigin => error.MissingNominalOrigin,
        .Conflict => error.ConflictingNominalType,
        .Invalid => error.InvalidModule,
    };
}
