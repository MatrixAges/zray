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
    source_first: usize = 0,
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
    pub fn init(self: *View, request: *const Request) void {
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
            .first = request.first,
            .source_first = request.source_first,
            .checked = request.checked,
        };

        self.input = .{
            .request = &self.data,
            .names = request.origins.names,
            .complete = request.complete,
            .validation = if (request.source_first == 0 and (request.first == 0 or request.checked)) &self.limits else null,
        };
    }
};

pub const Registration = struct {
    const Output = @import("merging/publication/view.zig");

    mapping: View,
    output: Output,
    offsets: Output.Offsets,
    pub fn init(self: *Registration, request: *const Request) void {
        self.mapping.init(request);

        self.offsets = Output.offsets(request.items);

        self.output.init(.{
            .allocator = request.allocator,
            .payload = request.allocator,
            .types = request.items,
            .origins = request.nominal,
            .offsets = &self.offsets,
        });
    }
    pub fn bind(self: *const Registration, comptime Target: type) Target {
        return .{
            .preparation = zx.columns.pointer(@FieldType(Target, "preparation"), &self.mapping.input),
            .publication = zx.columns.pointer(@FieldType(Target, "publication"), &self.output.target),
        };
    }
};

pub fn append(request: Request) Error![]const ir.TypeId {
    var arena = std.heap.ArenaAllocator.init(request.temporary);

    defer arena.deinit();

    var preparation: View = undefined;

    preparation.init(&request);

    const result = try publication.register(request.allocator, request.items, request.nominal, .{
        .temporary = arena.allocator(),
        .preparation = &preparation.input,
        .mapping_allocator = request.mapping_allocator,
    });

    return switch (result.status) {
        .Ready => result.mapping,
        .MissingOrigin => error.MissingNominalOrigin,
        .Conflict => error.ConflictingNominalType,
        .Invalid => error.InvalidModule,
    };
}
