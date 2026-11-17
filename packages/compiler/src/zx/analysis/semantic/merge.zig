const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Origins = @import("nominal_data");
const publication = @import("merging/commit.zig");
const Preparation = publication.Preparation;
const Data = std.meta.Child(@FieldType(Preparation, "request"));
const Table = std.meta.Child(@FieldType(Data, "source"));
const Bindings = std.meta.Child(@FieldType(Data, "origins"));
const Limits = std.meta.Child(@typeInfo(@FieldType(Preparation, "validation")).optional.child);
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

    const preparation: Preparation = .{
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

    const status = try publication.register(request.allocator, request.items, request.nominal, .{
        .temporary = arena.allocator(),
        .preparation = &preparation,
    });

    return switch (status) {
        .Ready => @ptrCast(mapping),
        .MissingOrigin => error.MissingNominalOrigin,
        .Conflict => error.ConflictingNominalType,
        .Invalid => error.InvalidModule,
    };
}
