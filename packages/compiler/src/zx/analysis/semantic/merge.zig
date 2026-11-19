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

pub const View = struct {
    source: Table,
    base: Table,
    origins: Bindings,
    base_origins: Bindings,
    data: Data,
    limits: Limits,
    input: Preparation,
    pub fn init(self: *View, request: *const Request, mapping: *[]u32) void {
        self.source = ir.TypeTable.borrow(Table, request.source);
        self.base = ir.TypeTable.borrow(Table, request.items.view());
        self.origins = Origins.Table.borrow(Bindings, request.origins);
        self.base_origins = Origins.Table.borrow(Bindings, request.nominal.view());
        self.limits = .{ .maximum_count = std.math.maxInt(u32), .scalar_count = std.enums.values(ir.Scalar).len };

        self.data = .{
            .source = &self.source,
            .origins = &self.origins,
            .base = &self.base,
            .base_origins = &self.base_origins,
            .mapping = @ptrCast(mapping),
            .first = request.first,
            .checked = request.checked,
        };

        self.input = .{
            .request = &self.data,
            .names = request.origins.names,
            .resource = @ptrCast(&request.mapping_allocator),
            .complete = request.complete,
            .validation = if (request.first == 0 or request.checked) &self.limits else null,
        };
    }
};

pub fn append(request: Request) Error![]const ir.TypeId {
    var mapping: []u32 = &.{};
    var arena = std.heap.ArenaAllocator.init(request.temporary);

    defer arena.deinit();
    errdefer request.mapping_allocator.free(mapping);

    var preparation: View = undefined;

    preparation.init(&request, &mapping);

    const status = try publication.register(request.allocator, request.items, request.nominal, .{
        .temporary = arena.allocator(),
        .preparation = &preparation.input,
    });

    return switch (status) {
        .Ready => @ptrCast(mapping),
        .MissingOrigin => error.MissingNominalOrigin,
        .Conflict => error.ConflictingNominalType,
        .Invalid => error.InvalidModule,
    };
}
