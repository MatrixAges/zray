const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const memory = zx.memory;
const Module = @import("../../artifact/model.zig").Module;
const Types = @import("../types.zig");
const Publication = @import("../../../analysis/semantic/merging/publication/view.zig");
const generated = @import("generated_artifact_type_registration");
const Input = std.meta.Child(generated.Input);
const State = std.meta.Child(@FieldType(generated.zx_pending, "store_0"));

const Host = struct {
    store_0: *State,
    output: *Publication,
    allocator: std.mem.Allocator,
    mappings: [][]const ir.TypeId,
    pub fn commit(self: *Host, pending: anytype) std.mem.Allocator.Error!void {
        if (pending.store_0) |row| {
            const mapping = try self.allocator.dupe(u32, row.mapping);

            errdefer self.allocator.free(mapping);

            try self.output.commit(row.publication.?);

            self.mappings[row.row] = @ptrCast(mapping);
        }
    }
};

const Tables = std.meta.Child(@FieldType(Input, "types"));
const Preparation = @import("../../../analysis/semantic/merging/commit.zig").Preparation;
const Request = std.meta.Child(@FieldType(Preparation, "request"));
const TypeTable = std.meta.Child(@FieldType(Request, "source"));
const Bindings = std.meta.Child(@FieldType(Request, "origins"));
const Limits = std.meta.Child(@FieldType(Input, "limits"));

pub fn register(types: *Types, modules: []const Module, order: []const u64, mappings: [][]const ir.TypeId, mapping_allocator: std.mem.Allocator, scratch: *std.heap.ArenaAllocator) Types.Error!void {
    const options: Publication.Options = .{
        .allocator = types.allocator,
        .payload = types.allocator,
        .types = &types.items,
        .origins = &types.origins.items,
    };

    var output: Publication = undefined;

    output.init(options);

    const type_rows = memory.bindSliceColumns(TypeTable, "types", modules);
    const origin_rows = memory.bindSliceColumns(Bindings, "nominal_types", modules);
    const type_storage = memory.bindColumnSet(TypeTable, false, &types.items);
    const origin_storage = memory.bindColumnSet(Bindings, false, &types.origins.items);
    const type_sources: []const memory.ReadColumn = &type_rows;
    const origin_sources: []const memory.ReadColumn = &origin_rows;
    const type_columns: memory.ColumnSet = &type_storage;
    const origin_columns: memory.ColumnSet = &origin_storage;
    const names = memory.borrowNestedColumn([]const []const u8, &.{ "nominal_types", "names" }, modules);
    var source: TypeTable = undefined;
    var base: TypeTable = undefined;
    var declared: Bindings = undefined;
    var known: Bindings = undefined;
    const limits: Limits = .{ .maximum_count = std.math.maxInt(u32), .scalar_count = std.enums.values(ir.Scalar).len };
    const publication: Publication.Target = output.target;

    const request: Input = .{
        .order = order,
        .types = &Tables{
            .rows = @ptrCast(&type_sources),
            .storage = @ptrCast(&type_columns),
            .row_view = @ptrCast(&source),
            .base_view = @ptrCast(&base),
        },
        .origins = &Tables{
            .rows = @ptrCast(&origin_sources),
            .storage = @ptrCast(&origin_columns),
            .row_view = @ptrCast(&declared),
            .base_view = @ptrCast(&known),
        },
        .names = @ptrCast(&names),
        .limits = &limits,
        .publication = zx.columns.pointer(@FieldType(Input, "publication"), &publication),
    };

    // The caller releases both owning arenas if a row fails after publishing data.
    var state: std.meta.Child(State) = .{ .row = 0, .mapping = &.{}, .publication = null };
    var state_ptr: State = &state;
    var host: Host = .{ .store_0 = &state_ptr, .output = &output, .allocator = mapping_allocator, .mappings = mappings };

    const status = generated.executeIn(scratch.allocator(), &request, &host) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidModule,
    };

    return switch (status) {
        .Ready => {},
        .MissingOrigin => error.MissingNominalOrigin,
        .Conflict => error.ConflictingNominalType,
        .Invalid => error.InvalidModule,
    };
}
